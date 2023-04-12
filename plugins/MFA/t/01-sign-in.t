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
    $mfa_valid_token = '123456';
    $mfa_invalid_token = '000000';

    $test_env = MT::Test::Env->new(
        PluginPath => ['TEST_ROOT/plugins'],
    );
    $ENV{MT_CONFIG} = $test_env->config_file;

    $test_env->save_file( 'plugins/MFA-Test/config.yaml', <<YAML );
name: MFA-Test
key: MFA-Test
id: MFA-Test

schema_version: 0.01
object_types:
  author:
    mfa_test_enabled: integer meta

callbacks:
  mfa_render_form: |
    sub {
        my (\$cb, \$app, \$param) = \@_;

        my \$tmpl = MT->model('template')->new;
        \$tmpl->text('MFA-Test');
        push \@{ \$param->{templates} }, \$tmpl;
        
        return 1;
    }
  mfa_verify_token: |
    sub {
        my \$app  = MT->app;
        my \$user = \$app->user;
        !\$user->mfa_test_enabled || (\$app->param('mfa_test_token') // '') eq '$mfa_valid_token';
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

my $locked_out_user = MT::Test::Permission->make_author;
$locked_out_user->set_password($password);
$locked_out_user->locked_out_time(time);
$locked_out_user->save or die $user->errstr;

my $mfa_user = MT::Test::Permission->make_author;
$mfa_user->set_password($password);
$mfa_user->mfa_test_enabled(1);
$mfa_user->save or die $user->errstr;

my $mfa_locked_out_user = MT::Test::Permission->make_author;
$mfa_locked_out_user->set_password($password);
$mfa_locked_out_user->mfa_test_enabled(1);
$mfa_locked_out_user->locked_out_time(time);
$mfa_locked_out_user->save or die $user->errstr;

my $app = MT::Test::App->new('MT::App::CMS');

sub insert_failedlogin {
    my ($user) = @_;
    my $failedlogin = MT->model('failedlogin')->new;
    $failedlogin->author_id($user->id);
    $failedlogin->remote_ip('127.0.0.1');
    $failedlogin->start(time);
    $failedlogin->save or die $failedlogin->errstr;
}

subtest 'sign in page' => sub {
    my $message_re = qr/Your password has been updated. Please sign in again./;
    subtest 'with mfa_password_updated=1' => sub {
        $app->get_ok({
            mfa_password_updated => 1,
        });
        $app->content_like($message_re);
    };

    subtest 'without parameters' => sub {
        $app->get_ok();
        $app->content_unlike($message_re);
    };
};

subtest 'sign in' => sub {
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

    subtest 'have configured MFA', sub {
        subtest 'valid password without security token' => sub {
            MT->model('failedlogin')->remove({ author_id => $mfa_user->id });
            $app->post_ok({
                username => $mfa_user->name,
                password => $password,
            });
            $app->content_unlike(qr/Dashboard/);
            is(MT->model('failedlogin')->count({ author_id => $mfa_user->id }), 1);
        };

        subtest 'invalid password without security token' => sub {
            MT->model('failedlogin')->remove({ author_id => $mfa_user->id });
            $app->post_ok({
                username => $mfa_user->name,
                password => 'Invalid - ' . $password,
            });
            $app->content_unlike(qr/Dashboard/);
            is(MT->model('failedlogin')->count({ author_id => $mfa_user->id }), 1);
        };

        subtest 'valid password with valid security token' => sub {
            insert_failedlogin($mfa_user);

            $app->post_ok({
                username       => $mfa_user->name,
                password       => $password,
                mfa_test_token => $mfa_valid_token,
            });
            $app->content_like(qr/Dashboard/);
            is(MT->model('failedlogin')->count({ author_id => $mfa_user->id }), 0);
        };

        subtest 'invalid password with valid security token' => sub {
            MT->model('failedlogin')->remove({ author_id => $mfa_user->id });

            $app->post_ok({
                username       => $mfa_user->name,
                password       => 'Invalid - ' . $password,
                mfa_test_token => $mfa_valid_token,
            });
            $app->content_unlike(qr/Dashboard/);
            is(MT->model('failedlogin')->count({ author_id => $mfa_user->id }), 1);
        };

        subtest 'valid password with invalid security token' => sub {
            MT->model('failedlogin')->remove({ author_id => $mfa_user->id });

            $app->post_ok({
                username       => $mfa_user->name,
                password       => $password,
                mfa_test_token => $mfa_invalid_token,
            });
            $app->content_unlike(qr/Dashboard/);
            is(MT->model('failedlogin')->count({ author_id => $mfa_user->id }), 1);
        };

        subtest 'invalid password with invalid security token' => sub {
            MT->model('failedlogin')->remove({ author_id => $mfa_user->id });

            $app->post_ok({
                username       => $mfa_user->name,
                password       => 'Invalid - ' . $password,
                mfa_test_token => $mfa_invalid_token,
            });
            $app->content_unlike(qr/Dashboard/);
            is(MT->model('failedlogin')->count({ author_id => $mfa_user->id }), 1);
        };

        subtest 'locked out' => sub {
            $app->post_ok({
                username => $mfa_locked_out_user->name,
                password => $password,
            });
            $app->content_unlike(qr/Dashboard/);
        };
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
        ok !$app->json->{error};
        like $app->json->{result}{html}, qr/MFA-Test/;
        is(MT->model('failedlogin')->count({ author_id => $user->id }), 1, 'Should not remove the failedlogin with this request.');
    };

    subtest 'invalid password' => sub {
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
