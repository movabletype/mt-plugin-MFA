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

applications:
  upgrade:
    methods:
      mfa_test_start_session: |
        sub {
            my \$app = shift;
            my \$user = MT->model('author')->load(scalar \$app->param('id'));
            \$app->start_session(\$user);
            \$app->{no_print_body} = 1;
            \$app->send_http_header('text/plain');
            \$app->print_encode(\$app->{session}->id);
        }

callbacks:
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

my $user = MT::Author->load(1);
$user->save or die $user->errstr;

my $mfa_user = MT::Test::Permission->make_author;
$mfa_user->mfa_test_enabled(1);
$mfa_user->is_superuser(1);
$mfa_user->save or die $mfa_user->errstr;

my $app = MT::Test::App->new('MT::App::Upgrader');

subtest 'override start_session' => sub {
    subtest "call `start_session` with a user who has no configured MFA" => sub {
        no warnings 'once';
        $app->get_ok({
            __mode => 'mfa_test_start_session',
            id     => $user->id,
        });
        my $session = MT->model('session')->load($app->content);
        is $session->get($MT::Plugin::MFA::STATUS_KEY), $MT::Plugin::MFA::STATUS_VERIFIED_WITHOUT_SETTINGS;
    };

    subtest "call `start_session` with a user who has configured MFA" => sub {
        $app->get_ok({
            __mode => 'mfa_test_start_session',
            id     => $mfa_user->id,
        });
        my $session = MT->model('session')->load($app->content);
        is $session->get($MT::Plugin::MFA::STATUS_KEY), undef;
    };
};

done_testing();
