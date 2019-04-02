use strict;
use warnings;

use Test::Most;

BEGIN {
    require Config::App;

    local $@;
    eval {
        Config::App->import('config/broken.yaml');
    };

    ok( $@ =~ m|Failed to parse "config/broken.yaml"; YAML::XS::Load Error|, '!!!!?????' );
}

done_testing;
