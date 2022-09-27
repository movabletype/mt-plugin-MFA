use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../../t/lib";

use Test::More;
use MT::Test::Env;

our $test_env;
BEGIN {
    $test_env = MT::Test::Env->new(
        DefaultLanguage => 'en_US',    ## for now
    );
    $ENV{MT_CONFIG} = $test_env->config_file;
}

use MT::Test;
use MT::Test::Permission;
use MT::Test::App;

$test_env->prepare_fixture('db');

my $password = 'password';
my $user     = MT::Author->load(1);
$user->set_password($password);
$user->save or die $user->errstr;

my $locked_out_user = MT::Test::Permission->make_author;
$locked_out_user->set_password($password);
$locked_out_user->locked_out_time(time);
$locked_out_user->save or die $user->errstr;

my $app = MT::Test::App->new('MT::App::CMS');

sub insert_failedlogin {
    my ($user) = @_;
    my $failedlogin = MT->model('failedlogin')->new;
    $failedlogin->author_id($user->id);
    $failedlogin->remote_ip('127.0.0.1');
    $failedlogin->start(time);
    $failedlogin->save or die $failedlogin->errstr;
}

subtest 'Should not affect to "sign in" function for users who have not configured MFA' => sub {
    subtest 'valid password' => sub {
        $app->post_ok({
            username => $user->name,
            password => $password,
        });
        $app->content_like(qr/Dashboard/);
    };

    subtest 'invalid password' => sub {
        MT->model('failedlogin')->remove({ author_id => $user->id });
        $app->post_ok({
            username => $user->name,
            password => 'Invalid - ' . $password,
        });
        $app->content_unlike(qr/Dashboard/);
        is(MT->model('failedlogin')->count({ author_id => $user->id }), 1);
    };

    subtest 'locked out' => sub {
        $app->post_ok({
            username => $locked_out_user->name,
            password => $password,
        });
        $app->content_unlike(qr/Dashboard/);
    };
};

subtest '__mode=mfa_login_form' => sub {
    subtest 'valid password' => sub {
        MT->model('failedlogin')->remove({ author_id => $user->id });
        insert_failedlogin($user);

        local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
        $app->post_ok({
            __mode   => 'mfa_login_form',
            username => $user->name,
            password => $password,
        });
        is_deeply($app->json, { "error" => undef, "result" => {} });
        is(MT->model('failedlogin')->count({ author_id => $user->id }), 1, 'Should not remove the failedlogin with this request.');
    };

    subtest 'valid password' => sub {
        MT->model('failedlogin')->remove({ author_id => $user->id });

        local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
        $app->post_ok({
            __mode   => 'mfa_login_form',
            username => $user->name,
            password => 'Invalid - ' . $password,
        });
        ok $app->json->{error};
        is(MT->model('failedlogin')->count({ author_id => $user->id }), 1, 'Should insert the failedlogin with this request.');
    };

    subtest 'locked out' => sub {
        local $ENV{HTTP_X_REQUESTED_WITH} = 'XMLHttpRequest';
        $app->post_ok({
            __mode   => 'mfa_login_form',
            username => $locked_out_user->name,
            password => $password,
        });
        ok $app->json->{error};
    };
};

done_testing();
