# NAME

Config::App - Cascading merged application configuration

# VERSION

version 1.19

[![test](https://github.com/gryphonshafer/Config-App/workflows/test/badge.svg)](https://github.com/gryphonshafer/Config-App/actions?query=workflow%3Atest)
[![codecov](https://codecov.io/gh/gryphonshafer/Config-App/graph/badge.svg)](https://codecov.io/gh/gryphonshafer/Config-App)

# SYNOPSIS

    use Config::App;
    use Config::App 'lib';
    use Config::App ();

    # seeks initial conf file "config/app.yaml" (then others)
    my $conf = Config::App->new;

    # seeks initial conf file "conf/settings.yaml"
    $ENV{CONFIGAPPINIT} = 'conf/settings.yaml';
    my $conf2 = Config::App->new;

    # seeks initial conf file "settings/conf.yaml"
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

    # same as new() except will silently return undef on failure
    my $conf5 = Config::App->find;

# DESCRIPTION

The intent of this module is to provide for projects (within a directory tree)
configuration fetcher and merger functionality that supports configuration files
that may include other files and "cascade" or merge bits of these files into an
"active" configuration based on server name, user account name the process is
running under, and/or enviornment variable flag. The goal being that a single
unified configuration can be built from a set of files (real files or URLs) and
slices of that configuration can be used as the active configuration in any
enviornment.

You can write configuration files in YAML or JSON. These files can be local
or served through some sort of URL.

## Cascading Configurations

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

## Configuration File Including

Any configuration file can "include" other files by including an "include"
keyword as a direct sub-key from a selector. For example:

    +|gryphon|other:
        database:
            password: other
        include: gryphon_settings.yaml

This will result in the file "gryphon\_settings.yaml" being read in and merged
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

### Optional Configuration File Including

Normally, if you "include" a location that doesn't exist, you'll get an error.
However, if you replace the "include" key word with "optional\_include", then
the location will be included if it exists and silently bypassed if it doesn't
exist.

### Pre-Including Configuration Files

When you "include" or "optional\_include" configuration files, the included file
or files are included after reading of the current or source configuration file.
Thus, any data in included files will overwrite data in the current or source
configuration file. If you want this reversed, with data in the current or
source configuration file  overwriting data in any included files, use
"preinclude" and "optional\_preinclude" respectively.

## Configuration File Finding

When a file is included, it's searched for starting at the current directory
of the program or application, as determined by [FindBin](https://metacpan.org/pod/FindBin) initially; and if
that failes, the current working directory. If the file is not found, it will be
looked for one directory level above, and so on and so on, until it's either
found or we get to the top directory level. This means that in a given
application with several nested directories of varying depth and programs within
each, you can use a single configuration file and not have to hard-code paths
into each program.

At any point, either in the `new()` constructor or as values to "include"
keys, you can stipulate URLs. If any of the configuration returned from
a URL includes an "include" key with a non-URL value, it will be assumed to be
a filename of a local file.

Any file can be either local or URL, and either YAML or JSON. The `new()`
constructor will believe anything that has a URL schema (i.e. "https://") is
a URL, and it will look at the file extension to determine if the file is
YAML or JSON. (As in: .yaml, .yml, .js, .json)

## Root Directory

The very first local file found (whether as the inital configuration file or as
the first local file found following a URL-based configuration) will determine
the "root\_dir" setting that falls under the "config\_app" auto-generated
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
and "root\_dir" will be set to "/home/gryphon/app", which can be access like so:

    $conf->get( 'config_app', 'root_dir' );

## Included Files

All included files, including the initial file, are listed in an arrayref,
which can be accessed like so:

    $conf->get( 'config_app', 'includes' );

This is mostly for debugging purposes, to know from where your configuration
was derived.

# METHODS

The following are the supported methods of this module:

## new

The constructor will return an object that can be used to query and alter the
derived cascaded configuration.

    # seeks initial conf file "config/app.yaml" (then others)
    my $conf = Config::App->new;

By default, with no parameters passed, the constructor assumes the initial
configuration file is, in order, one of the following:

- `config/app.yaml`
- `etc/config.yaml`
- `etc/conf.yaml`
- `etc/app.yaml`
- `config.yaml`
- `conf.yaml`
- `app.yaml`

You can stipulate an initial configuration file to the constructor:

    # seeks initial conf file "settings/conf.json"
    my $conf = Config::App->new('settings/conf.json');

You can also alternatively set an enviornment variable that will identify the
initial configuration file:

    # seeks initial conf file "conf/settings.yaml"
    $ENV{CONFIGAPPINIT} = 'conf/settings.yaml';
    my $conf = Config::App->new;

### Singleton

The `new()` constructor assumes that you'll want to have the configuration
object be a singleton, because within a single application, I assumed that it'd
be silly to compile the settings more than once. However, if you really want
a not-singleton behavior, pass any positive value as a second parameter to
the constructor.

    my $conf_0 = Config::App->new( 'file_0.yaml', 1 );
    my $conf_1 = Config::App->new( 'file_1.yaml', 1 );

## find

This is the same thing as `new()` except if unable to find a configuration
file, it will silently return `undef`.

## get

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

You would expect `$db` to be:

    {
        dbname => 'answer',
        number => 42,
    }

## put

This method allows you to alter the application configuration at runtime. It
expects that you provide a path to a node and the value that will replace that
node's current value.

    $conf->put( qw( database dbname new_db_name ) );

## conf

This method will return the entire derived cascaded configuration data set.
But more interesting is that you can pass in data structures to alter the
configuration.

    my $full_conf_as_data_structure = $conf->conf;

    my $new_full_conf_as_data_structure = $conf->conf({
        change => { some => { conf => 1138 } }
    });

## root\_dir

This is a shortcut to:

    $conf->get( qw( config_app root_dir ) );

## includes

This is a shortcut to:

    $conf->get( qw( config_app includes ) );

## deimport

If for whatever reason you need to completely remove Config::App and its data,
perhaps for a use case where you need to `use` it a second time as if it was
the first time, this method attempts to set that option up.

# LIBRARY DIRECTORY INJECTION

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

## Injection via configuration file setting

You can also inject a relative library path or set of paths by using the "libs"
keyword in the configuration file. The "libs" keyword should have either an
arrayref of relative paths or a string of a single relative path, relative to
the project's root directory.

# DIRECT DEPENDENCIES

[URI](https://metacpan.org/pod/URI), [LWP::UserAgent](https://metacpan.org/pod/LWP%3A%3AUserAgent), [Carp](https://metacpan.org/pod/Carp), [FindBin](https://metacpan.org/pod/FindBin), [JSON::XS](https://metacpan.org/pod/JSON%3A%3AXS), [YAML::XS](https://metacpan.org/pod/YAML%3A%3AXS), [POSIX](https://metacpan.org/pod/POSIX).

# SEE ALSO

You can look for additional information at:

- [GitHub](https://github.com/gryphonshafer/Config-App)
- [MetaCPAN](https://metacpan.org/pod/Config::App)
- [GitHub Actions](https://github.com/gryphonshafer/Config-App/actions)
- [Codecov](https://codecov.io/gh/gryphonshafer/Config-App)
- [CPANTS](http://cpants.cpanauthors.org/dist/Config-App)
- [CPAN Testers](http://www.cpantesters.org/distro/G/Config-App.html)

# AUTHOR

Gryphon Shafer <gryphon@cpan.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2015-2050 by Gryphon Shafer.

This is free software, licensed under:

    The Artistic License 2.0 (GPL Compatible)
