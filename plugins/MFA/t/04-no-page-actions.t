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
        return 1; # this plugin has no page actions
    }
YAML
}


use MT::Test;
use MT::Test::App;

$test_env->prepare_fixture('db');

my $user = MT::Author->load(1);
my $app  = MT::Test::App->new('MT::App::CMS');

subtest '__mode=view&_type=author' => sub {
    $app->login($user);
    $app->get_ok({
        __mode => 'view',
        _type  => 'author',
        id     => $user->id,
    });
    my $settings = $app->wq_find('#mfa_settings');
    is $settings->size, 0, '#mfa_settings should not be displayed if there is no page_actions';
};

done_testing();
