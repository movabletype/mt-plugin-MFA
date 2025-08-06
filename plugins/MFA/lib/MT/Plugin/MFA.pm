package MT::Plugin::MFA;

use strict;
use warnings;
use utf8;

use Class::Method::Modifiers qw(install_modifier);

our $STATUS_KEY                       = 'mfa_verified';
our $STATUS_VERIFIED_WITHOUT_SETTINGS = 1;
our $STATUS_VERIFIED_WITH_SETTINGS    = 2;
our $STATUS_REQUIRES_SETTINGS         = 3;

sub _plugin {
    MT->component(__PACKAGE__ =~ m/::([^:]+)\z/);
}

sub _insert_after {
    my ($tmpl, $before, $template_name) = @_;

    foreach my $t (@{ _plugin()->load_tmpl($template_name)->tokens }) {
        $tmpl->insertAfter($t, $before);
        $before = $t;
    }
}

sub _insert_after_by_name {
    my ($tmpl, $name, $template_name) = @_;

    my $before = pop @{ $tmpl->getElementsByName($name) || [] }
        or return;
    _insert_after($tmpl, $before, $template_name);
}

sub _insert_after_by_id {
    my ($tmpl, $id, $template_name) = @_;

    my $before = $tmpl->getElementById($id)
        or return;
    _insert_after($tmpl, $before, $template_name);
}

our $cached_mfa_enforcement;
sub mfa_enforcement {
    return $cached_mfa_enforcement //= _plugin()->get_config_value('mfa_enforcement');
}

sub template_param_login {
    my ($cb, $app, $param, $tmpl) = @_;
    $param->{plugin_mfa_version} = _plugin()->version;
    _insert_after_by_name($tmpl, 'layout/chromeless.tmpl', 'login_footer.tmpl');
    _insert_after_by_name($tmpl, 'logged_out',             'login_status_message.tmpl');
}

sub template_param_author_list_header {
    my ($cb, $app, $param, $tmpl) = @_;
    $param->{plugin_mfa_version} = _plugin()->version;
    _insert_after_by_name($tmpl, 'system_msg', 'author_list_header.tmpl');
}

sub template_param_edit_author {
    my ($cb, $app, $param, $tmpl) = @_;

    return 1 if $param->{new_object};

    $param->{plugin_mfa_version} = _plugin()->version;
    $param->{mfa_status}         = $app->session($STATUS_KEY) || 0;
    _insert_after_by_name($tmpl, 'related_content', 'edit_author.tmpl');
}

sub template_param_cfg_system_users {
    my ($cb, $app, $param, $tmpl) = @_;
    $param->{mfa_enforcement} = mfa_enforcement();
    _insert_after_by_id($tmpl, 'password-validation', 'cfg_system_users.tmpl');
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

sub get_configured_components {
    my ($app, $user) = @_;
    $user ||= $app->user;
    my $param = {
        user       => $user,
        components => [],
    };
    $app->run_callbacks('mfa_list_configured_settings', $app, $param);
    return $param->{components};
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
            $app->request('mfa_verify_token_result', $verified);

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

        if (
            $res[0]
            && (!$self->session($STATUS_KEY)
                || (mfa_enforcement() && $self->session($STATUS_KEY) == $STATUS_VERIFIED_WITHOUT_SETTINGS)))
        {
            if ($self->request('mfa_verify_token_result') || $self->session($STATUS_KEY)) {
                my $components = get_configured_components($self);
                my $status =
                      @$components      ? $STATUS_VERIFIED_WITH_SETTINGS
                    : mfa_enforcement() ? $STATUS_REQUIRES_SETTINGS
                    :                     $STATUS_VERIFIED_WITHOUT_SETTINGS;
                $self->session($STATUS_KEY, $status);
            } else {
                # If signed in with another app class, sign in again, because the MFA token has not been verified.
                return;
            }
        }

        if (($self->session($STATUS_KEY) || 0) == $STATUS_REQUIRES_SETTINGS) {
            my %methods = map { $_ => 1 } map { ref $_ eq 'ARRAY' ? @$_ : $_ } @{ MT->registry('mfa', 'allowed_methods_for_requires_settings') || [] };
            if (!$methods{ $self->mode }) {
                my $method_info = $self->request('method_info') || {};
                if ($self->param('xhr')
                    or (($method_info->{app_mode} || '') eq 'JSON'))
                {
                    $self->json_error(
                        _plugin()->translate('MFA setup is enforced by system policy. You must configure it before using this API.'),
                        401
                    );
                } else {
                    $self->redirect($self->mt_uri(mode => 'mfa_requires_settings'));
                }
                return;
            }
        }

        return @res;
    };
}

my $app_upgrader_initialized = 0;
sub init_app_upgrader {
    return if $app_upgrader_initialized;
    $app_upgrader_initialized = 1;

    install_modifier 'MT::App', 'after', 'start_session', sub {
        my ($self, $user) = @_;

        return unless $user;    # support only $app->start_session($user) pattern.

        my $components = get_configured_components($self, $user);

        if (!@$components) {
            $self->session($STATUS_KEY, $STATUS_VERIFIED_WITHOUT_SETTINGS);
        } else {
            # If the user has already set up MFA, start over with the sign-in form
        }
    };
}

sub mfa_settings_updated {
    my $app = MT->instance;

    my $prev_status = $app->session($STATUS_KEY) || 0;
    my $components  = get_configured_components($app);
    if (@$components) {
        $app->session($STATUS_KEY, $STATUS_VERIFIED_WITH_SETTINGS);
    } elsif ($prev_status == $STATUS_VERIFIED_WITH_SETTINGS && !@$components) {
        $app->session($STATUS_KEY, mfa_enforcement() ? $STATUS_REQUIRES_SETTINGS : $STATUS_VERIFIED_WITHOUT_SETTINGS);
    }

    1;
}

sub requires_settings {
    my ($app) = @_;

    if ($app->session($STATUS_KEY) != $STATUS_REQUIRES_SETTINGS) {
        $app->redirect($app->mt_uri);
        return;
    }

    $app->add_breadcrumb(_plugin()->translate('MFA Settings'));
    $app->load_tmpl(
        'mfa_requires_settings.tmpl', {
            screen_id => "mfa-requires-settings",
        });
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

        MT->model('session')->remove({
            kind => 'US',
            name => $user->id,
        });
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
        mfa_status   => ($app->session($STATUS_KEY) || 0) + 0,
    });
}

sub pre_save_config {
    my $app = MT->instance;

    return 1 unless $app->mode eq 'save_cfg_system_users';

    _plugin()->set_config_value('mfa_enforcement', $app->param('mfa_enforcement') ? 1 : 0);

    return 1;
}

1;
