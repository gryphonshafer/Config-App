package Config::App;
# ABSTRACT: Cascading merged application configuration

use strict;
use warnings;

use URI ();
use LWP::UserAgent ();
use Carp qw( croak carp );
use FindBin ();
use JSON::XS ();
use YAML::XS ();
use POSIX ();

# VERSION

$Carp::Internal{ (__PACKAGE__) }++;

sub _location {
    return $ENV{CONFIGAPPINIT} || 'config/app.yaml';
}

sub import {
    my $self = shift;

    my ( $root_dir, $config_file, $location, @libs );
    for (
        ( @_ > 1 )  ? ( $_[0], $_[-1], _location() ) :
        ( @_ == 1 ) ? ( $_[0], _location() )         : _location()
    ) {
        ( $root_dir, $config_file ) = _find_root_dir($_);
        if ( -f $config_file ) {
            $location = substr( $config_file, length($root_dir) + 1 );
            @libs     = grep { $location ne $_ } @_;
            last;
        }
    }

    unshift( @INC, $root_dir . "/$_" ) for ( @libs || 'lib' );
    eval { $self->new($location) };
    return;
}

{
    my $singleton;

    sub new {
        my ( $self, $location, $no_singleton ) = @_;
        return $singleton if ( not $no_singleton and $singleton );

        $location ||= _location();

        ( my $box = ( POSIX::uname )[1] ) =~ s/\..*$//;
        my $user  = getpwuid($>) || POSIX::cuserid;
        my $env   = $ENV{CONFIGAPPENV};
        my $conf  = {};

        _location_fetch( $box, $user, $env, $conf, $location );

        $self = bless( { _conf => $conf }, $self );
        $singleton = $self unless ($no_singleton);

        return $self;
    }
}

sub get {
    my $self = shift;
    my $data = $self->{_conf};

    $data = $data->{$_} for (@_);
    return $data;
}

sub put {
    my $self      = shift;
    my $new_value = pop;
    my $path      = [@_];
    my $node      = pop @{$path};

    eval {
        my $data = $self->{_conf};
        $data = $data->{$_} for ( @{$path} );
        $data->{$node} = $new_value;
    };

    return ($@) ? 0 : 1;
}

sub conf {
    my $self = shift;
    _merge_settings( $self->{_conf}, $_ ) for (@_);
    return $self->{_conf};
}

sub _location_fetch {
    my ( $box, $user, $env, $conf, $location, @source_path ) = @_;

    my ( $raw_config, $root_dir ) = _get_raw_config( $location, @source_path );
    return unless ($raw_config);

    $conf->{config_app}{root_dir} ||= $root_dir if ($root_dir);
    push( @{ $conf->{config_app}{includes} }, $root_dir . '/' . $location );

    my $set = _parse_config( $raw_config, $location, @source_path );

    _merge_settings( $conf, $_ ) for (
        grep { defined } (
            map {
                $set->{ join( '|', ( grep { defined } @$_ ) ) }
            } (
                [ 'default'         ],
                [ '+',  '+',   '+'  ], [ '+',  '+'   ],  [ '+'  ],
                [ $box, '+',   '+'  ], [ $box, '+'   ],  [ $box ],
                [ '+',  $user, '+'  ], [ '+',  $user ],
                [ $box, $user, '+'  ], [ $box, $user ],
                [ '+',  '+',   $env ],
                [ '+',  $user, $env ],
                [ $box, '+',   $env ],
                [ $box, $user, $env ],
            )
        )
    );

    _location_fetch( $box, $user, $env, $conf, $set->{include}, $location, @source_path )
        if ( $set->{include} );

    _location_fetch( $box, $user, $env, $conf, delete( $conf->{include} ), $location, @source_path )
        if ( $conf->{include} );

    _location_fetch( $box, $user, $env, $conf, \$set->{optional_include}, $location, @source_path )
        if ( $set->{optional_include} );

    if ( $conf->{optional_include} ) {
        my $optional_include = delete( $conf->{optional_include} );
        _location_fetch( $box, $user, $env, $conf, \$optional_include, $location, @source_path );
    }

    return;
}

sub _get_raw_config {
    my ( $location, @source_path ) = @_;

    my $optional = 0;
    if ( ref $location ) {
        $location = $$location;
        $optional = 1;
    }

    if ( URI->new($location)->scheme ) {
        my $ua = LWP::UserAgent->new(
            agent      => 'Config-App',
            cookie_jar => {},
            env_proxy  => 1,
        );

        my $res = $ua->get($location);

        if ( $res->is_success ) {
            return $res->decoded_content;
        }
        else {
            unless ($optional) {
                croak 'Failed to get '
                    . join( ' -> ', map { "\"$_\"" } @source_path, $location )
                    . '; '
                    . $res->status_line;
            }
            else {
                return '', '';
            }
        }
    }
    else {
        my ( $root_dir, $config_file ) = _find_root_dir($location);

        unless ( -f $config_file ) {
            unless ($optional) {
                croak 'Failed to find ' . join( ' -> ', map { "\"$_\"" } @source_path, $location );
            }
            else {
                return '', '';
            }
        }
        else {
            open( my $config_fh, '<', $config_file ) or croak "Failed to read $config_file; $!";
            return join( '', <$config_fh> ), $root_dir;
        }
    }
}

sub _find_root_dir {
    my ($location) = @_;
    $location ||= location();
    my ( $root_dir, $config_file );

    my @search_path = split( '/', $FindBin::Bin );
    while ( @search_path > 1 ) {
        $root_dir = join( '/', @search_path );
        $config_file = $root_dir . '/' . $location;
        last if ( -f $config_file );
        pop @search_path;
    }

    return $root_dir, $config_file;
}

{
    my $json_xs;

    sub _parse_config {
        my ( $raw_config, $location, @source_path ) = @_;

        my @types = qw( yaml json );
        if ( $location =~ /\.yaml$/ or $location =~ /\.yml$/ ) {
            @types = ( 'yaml', grep { $_ ne 'yaml' } @types );
        }
        elsif ( $location =~ /\.json$/ or $location =~ /\.js$/ ) {
            @types = ( 'json', grep { $_ ne 'json' } @types );
        }

        my ( $config, @errors );
        for my $type (@types) {
            if (
                my $error = do {
                    local $@;
                    eval {
                        if ( $type eq 'json' ) {
                            $json_xs ||= JSON::XS->new
                                ->utf8
                                ->relaxed
                                ->allow_nonref
                                ->allow_unknown
                                ->allow_blessed
                                ->allow_tags;

                            $config = $json_xs->decode($raw_config);
                        }
                        else {
                            $config = YAML::XS::Load($raw_config);
                        }
                    };
                    $@;
                }
            ) {
                push(
                    @errors,
                    'Failed to parse '
                        . join( ' -> ', map { "\"$_\"" } @source_path, $location )
                        . $_,
                );
            }

            last if ($config);
        }

        croak @errors if ( @errors and not $config );
        carp @errors if (@errors);

        return $config;
    }
}

sub _merge_settings {
    my ( $merge, $source ) = @_;
    return unless $source;

    for my $key ( keys %{$source} ) {
        if ( exists $merge->{$key} and ref( $merge->{$key} ) eq 'HASH' ) {
            _merge_settings( $merge->{$key}, $source->{$key} );
        }
        else {
            $merge->{$key} = $source->{$key};
        }
    }

    return;
}

1;
__END__
=pod

=begin :badges

=for markdown
[![Build Status](https://travis-ci.org/gryphonshafer/Config-App.svg)](https://travis-ci.org/gryphonshafer/Config-App)
[![Coverage Status](https://coveralls.io/repos/gryphonshafer/Config-App/badge.png)](https://coveralls.io/r/gryphonshafer/Config-App)

=end :badges

=head1 SYNOPSIS

    use Config::App;
    use Config::App 'lib';
    use Config::App ();

    # looks for initial conf file "config/app.yaml" at or above cwd
    my $conf = Config::App->new;

    # looks for initial conf file "conf/settings.yaml" at or above cwd
    $ENV{CONFIGAPPINIT} = 'conf/settings.yaml';
    my $conf2 = Config::App->new;

    # looks for initial conf file "settings/conf.yaml" at or above cwd
    my $conf3 = Config::App->new('settings/conf.yaml');

    # pulls initial conf file from URL
    my $conf4 = Config::App->new('https://example.com/config/app.yaml');

    # optional enviornment variable that can alter how cascading works
    $ENV{CONFIGAPPENV} = 'production';

    my $username = $conf->get( qw( database primary username ) );
    $conf->put( qw( database primary username new_username_value ) );

    my $full_conf_as_data_structure = $conf->conf;

    my $new_full_conf_as_data_structure = $conf->conf({
        change => { some => { conf => 1138 } }
    });

=head1 DESCRIPTION

The intent of this module is to provide an all-purpose enviornment setup helper
and configuration fetcher that allows configuration files to include other files
and "cascade" or merge bits of these files into the "active" configuration
based on server name, user account name the process is running under, and/or
enviornment variable flag. The goal being that a single unified configuration
can be built from a set of files (real files or URLs) and slices of that
configuration can be automatically used as the active configuration in any
enviornment. Thus, you can write configuration files once and never need to
change them based on the location to which the application is being deployed.

You can write configuration files in YAML or JSON. These files can be local
or served through some sort of URL.

=head2 Cascading Configurations

A configuration file can include a "default" section and any number of override
sections. Each overrides section begins with a pipe-delimited selector in the
form of: server name, user name (running the process), and value of the
CONFIGAPPENV enviornment variable. A "+" character means any and all values,
as does a missing value.

As a concrete example, assume the following YAML configuration file:

    default:
        database:
            username: prime
            password: insecure
    alderaan:
        database:
            username: primary
    titanic|gryphon:
        database:
            username: gryphon
    +|gryphon:
        database:
            password: gryphon
    +|gryphon|other:
        database:
            password: other

In this fairly silly and simple example, the "default" settings are at the top
and define a database username and password. Below that are overrides to the
default. On the server with a hostname of "alderaan", the database username is
"primary"; however, the password remains "insecure" (since it was defined
in the "default" section and left unchanged).

The "+|gryphon" selector means any hostname where the process is running under
the "gryphon" user account. The "+|gryphon|other" means the same but only if
CONFIGAPPENV enviornment variable is set to "other".

=head2 Configuration File Including

Any configuration file can "include" other files by including an "include"
keyword as a direct sub-key from a selector. For example:

    +|gryphon|other:
        database:
            password: other
        include: gryphon_settings.yaml

This will result in the file "gryphon_settings.yaml" being read in and merged
if and only if the "+|gryphon|other" selector is active. Any settings in this
included file with selectors that are active will be added even if they are
not the "+|gryphon|other" selector. However, since the file will only be
included if the "+|gryphon|other" selector is active, the selectors of the
sub-file are irrelevant if the "+|gryphon|other" selector is inactive.

Alternatively, you can opt to put "include" in the root namespace, which will
mean the sub-file is always included.

    +|gryphon|other:
        database:
            password: other
    include: gryphon_settings.yaml

=head3 Optional Configuration File Including

Normally, if you "include" a location that doesn't exist, you'll get an error.
However, if you replace the "include" key word with "optional_include", then
the location will be included if it exists and silently bypassed if it doesn't
exist.

=head2 Configuration File Finding

When a file is included, it's searched for starting at the current directory
of the program or application, as determined by L<FindBin>. If the file is not
found, it will be looked for one directory level above, and so on and so on,
until it's either found or we get to the top directory level. This means that
in a given application with several nested directories of varying depth and
programs within each, you can use a single configuration file and not have to
hard-code paths into each program.

At any point, either in the C<new()> constructor or as values to "include"
keys, you can stipulate URLs. If any of the configuration returned from
a URL includes an "include" key with a non-URL value, it will be assumed to be
a filename of a local file.

Any file can be either local or URL, and either YAML or JSON. The C<new()>
constructor will believe anything that has a URL schema (i.e. "https://") is
a URL, and it will look at the file extension to determine if the file is
YAML or JSON. (As in: .yaml, .yml, .js, .json)

=head2 Root Directory

The very first local file found (whether as the inital configuration file or as
the first local file found following a URL-based configuration) will determine
the "root_dir" setting that falls under the "config_app" auto-generated
configuration. What this means in practice is that if your application needs to
know its own root directory, set your first local configuration file include
to reference itself from the root directory of the application.

For example, let's say you have a directory structure like this:

    home
        gryphon
            app
                conf
                    settings.yaml
                lib
                    Module.pm
                bin
                    program.pl

Let's say then that the "program.pl" program includes this:

    my $conf = Config::App->new('conf/settings.yaml');

The result of this is that the configuration file "settings.yaml" will get found
and "root_dir" will be set to "/home/gryphon/app", which can be access like so:

    $conf->get( 'config_app', 'root_dir' );

=head2 Included Files

All included files, including the initial file, are listed in an arrayref,
which can be accessed like so:

    $conf->get( 'config_app', 'includes' );

This is mostly for debugging purposes, to know from where your configuration
was derived.

=head1 METHODS

The following are the supported methods of this module:

=head2 new

The constructor will return an object that can be used to query and alter the
derived cascaded configuration. By default, with no parameters passed, the
constructor assumes the initial configuration file is "config/app.yaml".

    # looks for initial conf file "config/app.yaml" at or above cwd
    my $conf = Config::App->new;

You can stipulate an initial configuration file to the constructor:

    # looks for initial conf file "settings/conf.json" at or above cwd
    my $conf = Config::App->new('settings/conf.json');

You can also alternatively set an enviornment variable that will identify the
initial configuration file:

    # looks for initial conf file "conf/settings.yaml" at or above cwd
    $ENV{CONFIGAPPINIT} = 'conf/settings.yaml';
    my $conf = Config::App->new;

=head3 Singleton

The C<new()> constructor assumes that you'll want to have the configuration
object be a singleton, because within a single application, I assumed that it'd
be silly to compile the settings more than once. However, if you really want
a not-singleton behavior, pass any positive value as a second parameter to
the constructor.

    my $conf_0 = Config::App->new( 'file_0.yaml', 1 );
    my $conf_1 = Config::App->new( 'file_1.yaml', 1 );

=head2 get

This returns a configuration setting or block of settings from the merged/active
application settings. To retrieve a setting of block, pass to get a list where
each node of the list is the node of a configuration tree address. Given the
following example YAML:

    default:
        database:
            dbname: answer
            number: 42

To retrieve this setting, you would:

    $conf->get( 'database', 'answer' );

If instead you made this call:

    my $db = $conf->get('database');

You would expect C<$db> to be:

    {
        dbname => 'answer',
        number => 42,
    }

=head2 put

This method allows you to alter the application configuration at runtime. It
expects that you provide a path to a node and the value that will replace that
node's current value.

    $conf->put( qw( database dbname new_db_name ) );

=head2 conf

This method will return the entire derived cascaded configuration data set.
But more interesting is that you can pass in data structures to alter the
configuration.

    my $full_conf_as_data_structure = $conf->conf;

    my $new_full_conf_as_data_structure = $conf->conf({
        change => { some => { conf => 1138 } }
    });

=head1 LIBRARY DIRECTORY INJECTION

By default, the call to use the library will result in the "lib" subdirectory
from the found root directory being unshifted to @INC. You can also stipulate
a directory alternative from "lib" in the use line.

    use Config::App;        # add "root_dir/lib"  to @INC
    use Config::App 'lib2'; # add "root_dir/lib2" to @INC

You can also supply multiple library directories and a specific configuration
file location relative to your project's root directory. If you specify a
relative configuration file location, it must be either the first or last value
provided.

    use Config::App qw( lib lib2 config.yaml );

To skip all this behavior, do this:

    use Config::App ();

=head1 DIRECT DEPENDENCIES

L<URI>, L<LWP::UserAgent>, L<Carp>, L<FindBin>, L<JSON::XS>, L<YAML::XS>, L<POSIX>.

=head1 SEE ALSO

You can look for additional information at:

=for :list
* L<GitHub|https://github.com/gryphonshafer/Config-App>
* L<CPAN|http://search.cpan.org/dist/Config-App>
* L<MetaCPAN|https://metacpan.org/pod/Config::App>
* L<AnnoCPAN|http://annocpan.org/dist/Config-App>
* L<Travis CI|https://travis-ci.org/gryphonshafer/Config-App>
* L<Coveralls|https://coveralls.io/r/gryphonshafer/Config-App>
* L<CPANTS|http://cpants.cpanauthors.org/dist/Config-App>
* L<CPAN Testers|http://www.cpantesters.org/distro/G/Config-App.html>

=cut
