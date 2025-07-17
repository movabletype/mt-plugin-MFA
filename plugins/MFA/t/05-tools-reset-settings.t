use strict;
use warnings;
use utf8;

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

$test_env->prepare_fixture('db');

use MT;
use MT::Util::UniqueID qw(create_md5_id);
use MT::Test;
use MT::Test::Permission;
use MT::Test::App;
use IPC::Run3 qw/run3/;

sub run {
    my @opts = @_;

    my $home = $ENV{MT_HOME};

    my @cmd = (
        $^X,
        '-I', File::Spec->catdir($test_env->root, 'lib'),
        '-I', File::Spec->catdir($home, 't/lib'),
        File::Spec->catfile($FindBin::Bin, '../../../tools/MFA/reset-settings'),
    );
    while (my ($key, $value) = splice @opts, 0, 2) {
        push @cmd, "--$key", $value;
    }

    note "GOING TO RUN " . (join " ", @cmd) . "\n\n";

    run3 \@cmd, \my $stdin, \my $stdout, \my $stderr;
    return wantarray ? ($stdout, $stderr) : $stdout;
}

subtest 'without arguments' => sub {
    my $user = MT::Test::Permission->make_author;
    my ($out, $err) = run();
    $user->refresh;
    like $err, qr/Usage:/;
    ok !$user->mfa_test_reset_count;
};

subtest '--username' => sub {
    subtest 'match' => sub {
        my $user = MT::Test::Permission->make_author;
        my ($out, $err) = run(username => $user->name);
        $user->refresh;
        is $out, "Reset settings for 1 users.\n";
        is $user->mfa_test_reset_count, 1;
    };
    subtest 'no match' => sub {
        my $user = MT::Test::Permission->make_author;
        my ($out, $err) = run(username => 'no-' . $user->name);
        $user->refresh;
        is $out, "Reset settings for 0 users.\n";
        ok !$user->mfa_test_reset_count;
    };
};

subtest '--email' => sub {
    subtest 'match' => sub {
        my $user = MT::Test::Permission->make_author;
        $user->email(create_md5_id() . '@example.com');
        $user->save;
        my ($out, $err) = run(email => $user->email);
        $user->refresh;
        is $out, "Reset settings for 1 users.\n";
        is $user->mfa_test_reset_count, 1;
    };
    subtest 'no match' => sub {
        my $user = MT::Test::Permission->make_author;
        my ($out, $err) = run(email => 'no-' . $user->email);
        $user->refresh;
        is $out, "Reset settings for 0 users.\n";
        ok !$user->mfa_test_reset_count;
    };
};

subtest '--all' => sub {
    my @users = map { MT::Test::Permission->make_author } 0..2;
    my ($out, $err) = run(all => 1);
    $_->refresh for @users;
    like $out, qr/Reset settings for \d+ users./;
    is($_->mfa_test_reset_count, 1) for @users;
};

subtest 'on error' => sub {
    my $user = MT::Test::Permission->make_author;
    $user->mfa_test_reset_count(99);
    $user->save;
    my ($out, $err) = run(username => $user->name);
    is $out, "Reset settings for 0 users.\n";
    like $err, qr{\QFailed to reset settings for user @{[$user->name]}(@{[$user->email]}) : Too many resets\E};
};

done_testing;
