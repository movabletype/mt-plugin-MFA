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
  cms:
    methods:
      mfa_test_update: |
        sub {
            my (\$app) = \@_;
            \$app->run_callbacks('mfa_settings_updated');
            \$app->{no_print_body} = 1;
            \$app->send_http_header('text/plain');
            \$app->print_encode('OK');
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

my $user   = MT::Author->load(1);
my $app    = MT::Test::App->new('MT::App::CMS');
my $plugin = MT->component('MFA');
$plugin->set_config_value('mfa_enforcement', 0);
$MT::Plugin::MFA::cached_mfa_enforcement = undef;

ok $MT::Plugin::MFA::STATUS_KEY;
ok $MT::Plugin::MFA::STATUS_VERIFIED_WITHOUT_SETTINGS;
ok $MT::Plugin::MFA::STATUS_VERIFIED_WITH_SETTINGS;
ok $MT::Plugin::MFA::STATUS_REQUIRES_SETTINGS;

subtest 'mfa_settings_updated' => sub {
    $app->login($user);

    my $session = MT::App::make_session($user);
    $app->{session} = $session->id;

    subtest 'has configured MFA' => sub {
        $user->mfa_test_enabled(1);
        $user->save or die $user->errstr;

        $app->get_ok({
            __mode => 'mfa_test_update',
        });

        $session = MT->model('session')->load($session->id);
        is $session->get($MT::Plugin::MFA::STATUS_KEY), $MT::Plugin::MFA::STATUS_VERIFIED_WITH_SETTINGS;
    };

    subtest 'has not configured MFA when mfa_enforcement is disabled' => sub {
        $user->mfa_test_enabled(0);
        $user->save or die $user->errstr;

        $app->get_ok({
            __mode => 'mfa_test_update',
        });

        $session = MT->model('session')->load($session->id);
        is $session->get($MT::Plugin::MFA::STATUS_KEY), $MT::Plugin::MFA::STATUS_VERIFIED_WITHOUT_SETTINGS;
    };

    subtest 'has not configured MFA when mfa_enforcement is enabled' => sub {
        $plugin->set_config_value('mfa_enforcement', 1);
        $MT::Plugin::MFA::cached_mfa_enforcement = undef;
        $user->mfa_test_enabled(0);
        $user->save or die $user->errstr;
        $session->set($MT::Plugin::MFA::STATUS_KEY, $MT::Plugin::MFA::STATUS_VERIFIED_WITH_SETTINGS);
        $session->save or die "Failed to save session: $!";

        $app->get_ok({
            __mode => 'mfa_test_update',
        });

        $session = MT->model('session')->load($session->id);
        is $session->get($MT::Plugin::MFA::STATUS_KEY), $MT::Plugin::MFA::STATUS_REQUIRES_SETTINGS;
    };
};

done_testing();
