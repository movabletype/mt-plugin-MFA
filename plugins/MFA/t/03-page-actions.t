use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../../t/lib";

use Test::More;
use MT::Test::Env;

our $test_env;
BEGIN {
    $test_env = MT::Test::Env->new(
        PluginPath => ['TEST_ROOT/plugins'],
    );
    $ENV{MT_CONFIG} = $test_env->config_file;

    $test_env->save_file('plugins/MFA-Test/config.yaml', <<'YAML' );
name: MFA-Test
key: MFA-Test
id: MFA-Test

callbacks:
  mfa_page_actions: |
    sub {
        my ($cb, $app, $actions) = @_;

        push @$actions, {
            label => 'MFA-Test',
            mode  => 'mfa_test_dialog',
        };

        1;
    }
YAML
}

use MT::Test;
use MT::Test::App;

$test_env->prepare_fixture('db');

my $user = MT::Author->load(1);
my $app  = MT::Test::App->new('MT::App::CMS');

subtest '__mode=mfa_page_actions' => sub {
    $app->login($user);

    local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
    $app->get_ok({
        __mode => 'mfa_page_actions',
    });
    is_deeply $app->json->{result}{page_actions}, [{
            label => 'MFA-Test',
            mode  => 'mfa_test_dialog',
        },
    ];
};

done_testing();
