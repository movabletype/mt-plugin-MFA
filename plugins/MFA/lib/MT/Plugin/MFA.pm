package MT::Plugin::MFA;

use strict;
use warnings;
use utf8;

use Class::Method::Modifiers qw(install_modifier);

sub _plugin {
    MT->component(__PACKAGE__ =~ m/::([^:]+)\z/);
}

sub _insert_after_by_name {
    my ($tmpl, $name, $template_name) = @_;

    my $before = pop @{ $tmpl->getElementsByName($name) || [] }
        or return;
    foreach my $t (@{ _plugin()->load_tmpl($template_name)->tokens }) {
        $tmpl->insertAfter($t, $before);
        $before = $t;
    }
}

sub template_param_login {
    my ($cb, $app, $param, $tmpl) = @_;
    $param->{plugin_mfa_version} = _plugin()->version;
    _insert_after_by_name($tmpl, 'layout/chromeless.tmpl', 'login_footer.tmpl');
}

sub template_param_author_list_header {
    my ($cb, $app, $param, $tmpl) = @_;
    _insert_after_by_name($tmpl, 'system_msg', 'author_list_header.tmpl');
}

sub template_param_edit_author {
    my ($cb, $app, $param, $tmpl) = @_;

    $param->{mfa_page_actions} = [];
    $app->run_callbacks('mfa_page_actions', $app, $param->{mfa_page_actions});
    _insert_after_by_name($tmpl, 'related_content', 'edit_author.tmpl');
}

our $skip_process_login_result = 0;

sub login_form {
    my $app = shift;

    require MT::Auth;
    require MT::Author;

    my $return_with_invalid_login = sub {
        $app->login();    # call MT::App::login to record log and failed login
        $app->json_error($app->translate('Invalid login.'));
    };

    my $ctx = MT::Auth->fetch_credentials({ app => $app })
        or return $return_with_invalid_login->();

    my $res = MT::Auth->validate_credentials($ctx, { skip_callbacks => 1 }) || MT::Auth::UNKNOWN();

    if (MT->config->MFAShowFormOnlyToAuthenticatedUser) {
        return $return_with_invalid_login->() unless $res == MT::Auth::NEW_LOGIN();
    } else {
        unless ($app->user) {
            my $user = $app->user_class->load(
                { name   => $ctx->{username}, type => MT::Author->AUTHOR },
                { binary => { name => 1 } });
            $app->user($user);
        }
    }

    my $param = {
        templates => [],
    };

    $app->run_callbacks('mfa_render_form', $app, $param);

    unless (@{ $param->{templates} }) {
        return $app->json_result({});
    }

    return $app->json_result({
        html => join "\n",
        map({ ref $_ ? MT->build_page_in_mem($_) : $_ } (
                $app->load_tmpl('login_form_header.tmpl'),
                @{ $param->{templates} },
                $app->load_tmpl('login_form_footer.tmpl'),
        )),
    });
}

sub validate_credentials {
    my ($cb, $app, $param) = @_;

    $param->{result} = MT::Auth::INVALID_PASSWORD()
        if ($param->{result} == MT::Auth::NEW_LOGIN() && !MT->app->run_callbacks('mfa_verify_token'));

    1;
}

sub reset_settings {
    my ($app) = @_;

    $app->validate_magic() or return;
    return $app->permission_denied()
        unless $app->user->is_superuser;
    return $app->error($app->translate("Invalid request."))
        if $app->request_method ne 'POST';

    my $class = $app->model('author');
    $app->setup_filtered_ids
        if $app->param('all_selected');

    my $status = 1;
    for my $id ($app->can('multi_param') ? $app->multi_param('id') : $app->param('id')) {
        next unless $id;
        my $user = $class->load($id);
        next unless $user;
        $status &&= $app->run_callbacks('mfa_reset_settings', $app, { user => $user });
    }

    $app->add_return_arg(saved_status  => $status ? 'mfa_reset' : 'mfa_reset_failed');
    $app->add_return_arg(is_power_edit => 1)
        if $app->param('is_power_edit');

    $app->call_return;
}

1;
