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

sub login_form {
    my $app = shift;

    require MT::Author;

    my $username = $app->param('username');
    my $user_class = $app->user_class;
    my ($author) = $user_class->load(
        {   name      => $username,
            type      => MT::Author::AUTHOR(),
            auth_type => 'MT'
        },
        { binary => { name => 1 } }
    );

    return $app->json_result({}) unless $author;

    my $param = {
        templates => [],
        author    => $author,
    };

    $app->run_callbacks('mfa_render_form', $app, $param);

    return $app->json_result({
        html => join "\n", map {
            ref $_ ? MT->build_page_in_mem($_) : $_
        } @{$param->{templates}},
    });
}

sub init_app {
    my @auth_modes = split( /\s+/, MT->config->AuthenticationModule );
    foreach my $auth_mode (@auth_modes) {
        my $auth_module_name = 'MT::Auth::' . $auth_mode;
        eval 'require ' . $auth_module_name;

        install_modifier $auth_module_name, 'around', 'validate_credentials', sub {
            my $orig = shift;
            my $self = shift;

            my $res = $self->$orig(@_);

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
