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
use MT::Test::Permission;
use MT::Test::App;
use MT::Util;
use MT::Util::Captcha;
use MT::Util::UniqueID;

$test_env->prepare_fixture('db');

my $password = 'password';
my $user     = MT::Author->load(1);
$user->set_password($password);
$user->save or die $user->errstr;

my $app = MT::Test::App->new('MT::App::CMS');

sub _start_recover {
    my $user = shift;
    require MT::Util::Captcha;
    my $salt    = MT::Util::Captcha->_generate_code(8);
    my $expires = time + (60 * 60);
    my $token   = MT::Util::perl_sha1_digest_hex($salt . $expires . MT->config->SecretToken);

    $user->password_reset($salt);
    $user->password_reset_expires($expires);
    $user->save;
    $token;
}

subtest '__mode=new_pw' => sub {
    subtest '__mode should be replaced' => sub {
        my $token = _start_recover($user);
        $app->get_ok({
            __mode => 'new_pw',
            token  => $token,
            email  => $user->email,
        });
        $app->content_like(qr/value="mfa_new_password"/);
    };

    subtest 'should not be replaced if token is invalid' => sub {
        my $token = _start_recover($user);
        $app->get_ok({
            __mode => 'new_pw',
            token  => $token . '-invalid',
            email  => $user->email,
        });
        $app->content_unlike(qr/value="mfa_new_password"/);
    };
};

subtest '__mode=mfa_new_password' => sub {
    subtest 'redirect target should be replaced' => sub {
        local $app->{no_redirect} = 1;
        my $new_password = MT::Util::UniqueID->create_md5_id();
        my $token = _start_recover($user);
        $app->post_ok({
            __mode         => 'mfa_new_password',
            token          => $token,
            email          => $user->email,
            username       => $user->name,
            password       => $new_password,
            password_again => $new_password,
        });
        my $location = $app->last_location;
        ok $location->query_param('mfa_password_updated');
        ok !$location->query_param('__mode');
    };

    subtest 'the result is the same as the original new_password if not redirected' => sub {
        local $app->{no_redirect} = 1;
        my $new_password = MT::Util::UniqueID->create_md5_id();
        my $token = _start_recover($user);
        $app->post_ok({
            __mode         => 'mfa_new_password',
            token          => $token,
            email          => $user->email,
            username       => $user->name,
            password       => $new_password,
            password_again => $new_password . '-typo',
        });
        $app->content_like(qr/value="mfa_new_password"/);
    };
};

done_testing();
