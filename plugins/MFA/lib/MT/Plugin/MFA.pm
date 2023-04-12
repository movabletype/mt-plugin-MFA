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
    _insert_after_by_name($tmpl, 'logged_out', 'login_status_message.tmpl');
}

sub template_param_author_list_header {
    my ($cb, $app, $param, $tmpl) = @_;
    $param->{plugin_mfa_version} = _plugin()->version;
    _insert_after_by_name($tmpl, 'system_msg', 'author_list_header.tmpl');
}

sub template_param_edit_author {
    my ($cb, $app, $param, $tmpl) = @_;
    _insert_after_by_name($tmpl, 'related_content', 'edit_author.tmpl');
}

sub template_source_new_password {
    my ($cb, $app, $tmpl) = @_;
    $$tmpl =~ s{\bvalue="new_pw"}{value="mfa_new_password"};
}

our $pre_check_credentials = 0;
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

    # FIXME: Calling an internal method.
    # This works correctly in MT7, but will likely not work in MT8 or later versions, so it needs to be fixed soon.
    my $res = do {
        local $pre_check_credentials = 1;
        MT::Auth::_handle('validate_credentials', $ctx) || MT::Auth::UNKNOWN();
    };
    if ($res != MT::Auth::SUCCESS()) {
        require MT::Lockout;
        if (MT::Lockout->is_locked_out($app, $app->remote_ip, $ctx->{username})) {
            $res = MT::Auth::LOCKED_OUT();
        }
    }

    return $return_with_invalid_login->()
        unless $res == MT::Auth::NEW_LOGIN();

    my $param = {
        templates => [],
        scripts   => [],
    };

    $app->run_callbacks('mfa_render_form', $app, $param);

    unless (@{ $param->{templates} }) {
        return $app->json_result({});
    }

    return $app->json_result({
        html => join(
            "\n",
            map({ ref $_ ? MT->build_page_in_mem($_) : $_ } (
                    $app->load_tmpl('login_form_header.tmpl'),
                    @{ $param->{templates} },
                    $app->load_tmpl('login_form_footer.tmpl'),
            ))
        ),
        scripts => $param->{scripts},
    });
}

our $disable_login = 0;
sub new_password {
    my $app = shift;
    require MT::CMS::Tools;
    local $disable_login = 1;
    my $res = MT::CMS::Tools::new_password($app);

    if (ref $app eq 'MT::App::CMS' && $app->{redirect}) {
        # password has been updated
        $app->redirect($app->mt_uri(args => { mfa_password_updated => 1 }));
        return;
    }

    return $res;
}

my $app_initialized = 0;
sub init_app {
    return if $app_initialized;
    $app_initialized = 1;

    my @auth_modes = split(/\s+/, MT->config->AuthenticationModule);
    foreach my $auth_mode (@auth_modes) {
        my $auth_module_name = 'MT::Auth::' . $auth_mode;
        eval 'require ' . $auth_module_name;
        next if $@;

        install_modifier $auth_module_name, 'around', 'validate_credentials', sub {
            my $orig  = shift;
            my $self  = shift;
            my ($ctx) = @_;
            my $app   = MT->app;

            my $res = $self->$orig(@_);

            return $res unless $app && $app->isa('MT::App::CMS');

            return $res if $pre_check_credentials;
            return $res unless $res == MT::Auth::NEW_LOGIN();

            my $verified = $app->run_callbacks('mfa_verify_token');
            $app->request('mfa_verified', $verified);

            $verified
                ? $res
                : MT::Auth::INVALID_PASSWORD();
        };
    }

    install_modifier 'MT::App', 'around', 'login', sub {
        my $orig = shift;
        my $self = shift;

        return if $disable_login;

        my @res = $self->$orig(@_);

        return @res unless $self->isa('MT::App::CMS');

        if ($res[0] && !$self->session('mfa_verified')) {
            if ($self->request('mfa_verified')) {
                $self->session('mfa_verified', 1);
                $self->session->save;
            } else {
                # If signed in with another app class, sign in again, because the MFA token has not been verified.
                return;
            }
        }

        return @res;
    };
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

sub page_actions {
    my ($app) = @_;

    $app->validate_param({
        id => [qw/ID/],
    }) or return;

    # TODO: Allow super users to also perform actions on other users.
    my $page_user_id = $app->param('id');
    if ($page_user_id && $page_user_id != $app->user->id) {
        return $app->json_result({ page_actions => [] });
    }

    my $param = {
        mfa_page_actions => [],
    };
    $app->run_callbacks('mfa_page_actions', $app, $param->{mfa_page_actions});

    return $app->json_result({
        page_actions => $param->{mfa_page_actions},
    });
}

1;
