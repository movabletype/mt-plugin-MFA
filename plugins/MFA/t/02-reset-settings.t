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

    $test_env->save_file( 'plugins/MFA-Test/config.yaml', <<'YAML' );
name: MFA-Test
key: MFA-Test
id: MFA-Test

schema_version: 0.01
object_types:
  author:
    mfa_test_reset_count: integer meta

callbacks:
  mfa_reset_settings: |
    sub {
      my ($cb, $app, $param) = @_;
      my $user = $param->{user};

      if (($user->mfa_test_reset_count // 0) == 99) {
        $cb->error('Too many resets');
        return; # raise error
      }

      $user->mfa_test_reset_count(($user->mfa_test_reset_count // 0)+1);
      $user->save;
    }
YAML
}

use MT::Test;
use MT::Test::Permission;
use MT::Test::App;

$test_env->prepare_fixture('db');

my $admin = MT::Author->load(1);
my $app = MT::Test::App->new('MT::App::CMS');

subtest '__mode=mfa_reset' => sub {
    $app->login($admin);

    subtest 'select users' => sub {
        my @selected_users = map { MT::Test::Permission->make_author } 0..2;
        my @not_selected_users = map { MT::Test::Permission->make_author } 0..2;
        $app->post_ok({
            __mode      => 'mfa_reset',
                        _type       => 'author',
            return_args => '__mode=list&blog_id=0&_type=author',
            id          => [ map { $_->id } @selected_users ],
        });
        $_->refresh for (@selected_users, @not_selected_users);
        is($_->mfa_test_reset_count, 1) for @selected_users;
        ok(!$_->mfa_test_reset_count) for @not_selected_users;
        like $app->last_location, qr/\?__mode=list&blog_id=0&_type=author&saved_status=mfa_reset/, "saved_status is mfa_reset";
    };

    subtest 'all users' => sub {
        my @users = map { MT::Test::Permission->make_author } 0..2;
        $app->post_ok({
            __mode      => 'mfa_reset',
            _type       => 'author',
            return_args => '__mode=list&blog_id=0&_type=author',
            all_selected => 1,
        });
        $_->refresh for @users;
        is($_->mfa_test_reset_count, 1) for @users;
        like $app->last_location, qr/\?__mode=list&blog_id=0&_type=author&saved_status=mfa_reset/, "saved_status is mfa_reset";
    };

    subtest 'failed to reset some users' => sub {
        my @users = map { MT::Test::Permission->make_author } 0..2;
        my $too_many_resets_user = MT::Test::Permission->make_author;
        $too_many_resets_user->mfa_test_reset_count(99);
        $too_many_resets_user->save;
        $app->post_ok({
            __mode      => 'mfa_reset',
            _type       => 'author',
            return_args => '__mode=list&blog_id=0&_type=author',
            all_selected => 1,
        });
        $_->refresh for @users;
        is($_->mfa_test_reset_count, 1) for @users;
        like $app->last_location, qr/\?__mode=list&blog_id=0&_type=author&saved_status=mfa_reset_failed/, "saved_status is mfa_reset_failed";
    };

    my $non_admin_user = MT::Test::Permission->make_author;
    $app->login($non_admin_user);
    subtest 'Return "permission denied" for non admin user' => sub {
        my $user = MT::Test::Permission->make_author;
        $app->post_ok({
            __mode      => 'mfa_reset',
            _type       => 'author',
            return_args => '__mode=list&blog_id=0&_type=author',
            all_selected => 1,
        });
        $user->refresh;
        ok(!$user->mfa_test_reset_count);
        $app->has_permission_error("reset by non admin user");
    };
};

done_testing();
