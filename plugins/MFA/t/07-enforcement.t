use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../../t/lib";

use Test::More;
use MT::Test::Env;

our $mfa_valid_token;
our $mfa_invalid_token;
our $test_env;
BEGIN {
    $mfa_valid_token   = '123456';

    $test_env = MT::Test::Env->new(
        PluginPath => ['TEST_ROOT/plugins'],
    );
    $ENV{MT_CONFIG} = $test_env->config_file;

    $test_env->save_file('plugins/MFA-Test/config.yaml', <<YAML );
name: MFA-Test
key: MFA-Test
id: MFA-Test

schema_version: 0.01
object_types:
  author:
    mfa_test_enabled: integer meta

mfa:
  allowed_methods_for_requires_settings:
    - mfa_test_safe_method

applications:
  cms:
    methods:
      mfa_test_safe_method: |
        sub {
            my (\$app) = \@_;
            \$app->{no_print_body} = 1;
            \$app->send_http_header('text/plain');
            \$app->print_encode('OK');
        }
      mfa_test_dangerous_method:
        handler: |
            sub {
                my (\$app) = \@_;
                \$app->{no_print_body} = 1;
                \$app->send_http_header('text/plain');
                \$app->print_encode('Not allowed');
            }
        app_mode: JSON

callbacks:
  mfa_verify_token: |
    sub {
        my \$app  = MT->app;
        my \$user = \$app->user;
        !\$user->mfa_test_enabled || (\$app->param('mfa_test_token') // '') eq '$mfa_valid_token';
    }
  mfa_list_configured_settings: |
    sub {
        my (\$cb, \$app, \$param) = \@_;
        if (\$param->{user}->mfa_test_enabled) {
            push \@{\$param->{components}}, \$app->component('MFA-Test');
        }
        return 1;
    }
YAML
}

use MT::Test;
use MT::Test::Permission;
use MT::Test::App;

$test_env->prepare_fixture('db');

my $password = 'password';
my $user     = MT::Author->load(1);
$user->set_password($password);
$user->save or die $user->errstr;

my $mfa_user = MT::Test::Permission->make_author;
$mfa_user->set_password($password);
$mfa_user->mfa_test_enabled(1);
$mfa_user->is_superuser(1);
$mfa_user->save or die $mfa_user->errstr;

my $app = MT::Test::App->new(
    app_class   => 'MT::App::CMS',
    no_redirect => 1,
);
my $plugin = MT->component('MFA');
$plugin->set_config_value('mfa_enforcement', 1);

subtest 'mfa_enforcement: true' => sub {
    subtest "Sign in as a user who has no configured MFA" => sub {
        subtest 'allowed methods' => sub {
            for my $mode (qw(mfa_requires_settings mfa_page_actions mfa_test_safe_method)) {
                subtest "GET $mode" => sub {
                    $app->get_ok({
                        __mode   => $mode,
                        username => $user->name,
                        password => $password,
                    });
                    ok !$app->{locations};
                };
            }
        };

        subtest 'not allowed methods' => sub {
            for my $mode (qw(mfa_test_dangerous_method)) {
                local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
                subtest "GET $mode" => sub {
                    $app->get({
                        __mode   => $mode,
                        username => $user->name,
                        password => $password,
                    });
                    $app->status_is(401);
                    ok $app->json->{error};
                };
            }
            for my $mode (qw(dashboard list_template)) {
                subtest "GET $mode" => sub {
                    $app->get_ok({
                        __mode   => $mode,
                        username => $user->name,
                        password => $password,
                    });
                    like $app->last_location, qr/__mode=mfa_requires_settings/;
                };
            }
        };
    };

    subtest "Sign in as a user who has configured MFA" => sub {
        subtest 'allowed to access all methods' => sub {
            for my $mode (qw(dashboard list_template)) {
                (my $screen_id = $mode) =~ s/_/-/g;
                subtest "GET $mode" => sub {
                    $app->get_ok({
                        __mode         => $mode,
                        username       => $mfa_user->name,
                        password       => $password,
                        mfa_test_token => $mfa_valid_token,
                    });
                    like $app->content, qr/<html[^>]*data-screen-id="$screen_id"/;
                };
            }
        };
    };
};

done_testing();
