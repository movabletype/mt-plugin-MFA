use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../../t/lib";

use Test::More;
use MT::Test::Env;

our $test_env;
BEGIN {
    $test_env = MT::Test::Env->new;
    $ENV{MT_CONFIG} = $test_env->config_file;
}

use MT::Test;
use MT::Test::App;
use MT::Test::Permission;

$test_env->prepare_fixture('db');

my $user   = MT::Author->load(1);
my $app    = MT::Test::App->new('MT::App::CMS');
my $plugin = MT->component('MFA');

subtest '__mode=cfg_system_users' => sub {
    $plugin->set_config_value('mfa_enforcement', 0);
    undef $MT::Plugin::MFA::cached_mfa_enforcement;

    $app->login($user);

    subtest 'mfa_enforcement is disabled' => sub {
        $app->get_ok({ __mode => 'cfg_system_users' });
        ok !$app->wq_find('input[name="mfa_enforcement"]')->attr('checked');
    };

    $plugin->set_config_value('mfa_enforcement', 1);
    undef $MT::Plugin::MFA::cached_mfa_enforcement;

    subtest 'mfa_enforcement is enabled' => sub {
        $app->get_ok({ __mode => 'cfg_system_users' });
        ok $app->wq_find('input[name="mfa_enforcement"]')->attr('checked');
    };
};

subtest '__mode=save_cfg_system_users' => sub {
    $plugin->set_config_value('mfa_enforcement', 0);
    $app->login($user);

    subtest 'enable mfa_enforcement' => sub {
        $app->post_ok({
            __mode          => 'save_cfg_system_users',
            minimum_length  => 8,
            mfa_enforcement => 1
        });
        ok $plugin->get_config_value('mfa_enforcement');
    };

    subtest 'disable mfa_enforcement' => sub {
        $app->get_ok({
            __mode          => 'save_cfg_system_users',
            minimum_length  => 8,
            mfa_enforcement => ''
        });
        ok !$plugin->get_config_value('mfa_enforcement');
    };
};

done_testing();
