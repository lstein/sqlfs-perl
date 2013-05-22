#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

my $dsn = shift || 'dbi:mysql:filesystem;user=lstein;password=blah';
my $mnt = shift || "$Bin/../foo";

#my $fs = DBI::Filesystem->new($dsn,'create');
my $fs = DBI::Filesystem->new($dsn);
$fs->mount($mnt);

exit 0;
