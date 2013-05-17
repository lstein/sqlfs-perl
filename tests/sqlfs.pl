#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

my $fs = DBI::Filesystem->new('dbi:mysql:filesystem;user=lstein;password=blah','create');
$fs->mount("$Bin/../foo");

exit 0;
