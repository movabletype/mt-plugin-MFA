package MT::Plugin::MFA;

use strict;
use warnings;
use utf8;

use Class::Method::Modifiers qw(install_modifier);

sub plugin {
    MT->component(__PACKAGE__ =~ m/::([^:]+)\z/);
}

sub insert_after_by_name {
    my ($tmpl, $name, $template_name) = @_;

    my $before = pop @{$tmpl->getElementsByName($name) || []}
        or return;
    foreach my $t ( @{ plugin()->load_tmpl($template_name)->tokens } ) {
        $tmpl->insertAfter( $t, $before );
        $before = $t;
    }
}

sub template_param_login {
    my ($cb, $app, $param, $tmpl) = @_;
    insert_after_by_name($tmpl, 'include/chromeless_footer.tmpl', 'login_footer.tmpl');
    insert_after_by_name($tmpl, 'layout/chromeless.tmpl', 'login_footer.tmpl');
}

sub template_param_author_list_header {
    my ($cb, $app, $param, $tmpl) = @_;
    insert_after_by_name($tmpl, 'system_msg', 'author_list_header.tmpl');
}

sub show_settings {
    my $app = shift;

    my $param = {
        templates => [],
    };

    $app->run_callbacks('mfa_show_settings', $app, $param);

    my $tmpl = plugin()->load_tmpl('settings.tmpl');
    $tmpl->param({page_content => join "\n", map {
            ref $_ ? MT->build_page_in_mem($_) : $_
        } @{$param->{templates}},
    });

    $tmpl;
}

our $skip_process_login_result = 0;

sub login_form {
    my $app = shift;

    require MT::Auth;
    require MT::Author;

    my $ctx = MT::Auth->fetch_credentials({app => $app})
        or return $app->json_result({});

    $ctx->{mfa_validate_credentials} = 1;

    my $res = do {
        local $skip_process_login_result = 1;
        MT::Auth->validate_credentials($ctx) || MT::Auth::UNKNOWN();
    };

    unless ($app->user) {
        my $user = $app->user_class->load(
            { name   => $ctx->{username}, type => MT::Author->AUTHOR },
            { binary => { name => 1 } });
        $app->user($user);
    }

    my $param = {
        templates => [],
    };

    $app->run_callbacks('mfa_render_form', $app, $param);

    return $app->json_result({
        html => join "\n", map {
            ref $_ ? MT->build_page_in_mem($_) : $_
        } @{$param->{templates}},
    });
}

sub init_app {
    require MT::Lockout;
    install_modifier 'MT::Lockout', 'around', 'process_login_result', sub {
        my $orig = shift;
        my $self = shift;

        $self->$orig(@_) unless $skip_process_login_result;
    };

    my @auth_modes = split( /\s+/, MT->config->AuthenticationModule );
    foreach my $auth_mode (@auth_modes) {
        my $auth_module_name = 'MT::Auth::' . $auth_mode;
        eval 'require ' . $auth_module_name;

        install_modifier $auth_module_name, 'around', 'validate_credentials', sub {
            my $orig = shift;
            my $self = shift;
            my ($ctx) = @_;

            my $res = $self->$orig(@_);

            return $res if $ctx->{mfa_validate_credentials};

            require MT::Auth;

            return $res unless $res == MT::Auth::NEW_LOGIN();

            return MT->app->run_callbacks('mfa_verify_token')
                ? $res
                : MT::Auth::INVALID_PASSWORD();
        };
    }
}

sub reset_settings {
    my ($app) = @_;

    $app->validate_magic() or return;
    return $app->permission_denied()
        unless $app->user->is_superuser;
    return $app->error( $app->translate("Invalid request.") )
        if $app->request_method ne 'POST';

    my $class = $app->model('author');
    $app->setup_filtered_ids
        if $app->param('all_selected');

    for my $id ($app->can('multi_param') ? $app->multi_param('id') : $app->param('id')) {
        next unless $id;
        my $user = $class->load($id);
        next unless $user;
        $app->run_callbacks('mfa_reset_settings', $app, {user => $user});
    }

    $app->add_return_arg(saved_status => 'mfa_reset');
    $app->add_return_arg(is_power_edit => 1)
        if $app->param('is_power_edit');

    $app->call_return;
}

1;
