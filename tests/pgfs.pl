#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

my $dsn = shift || 'dbi:Pg:dbname=filesystem;';
my $mnt = shift || "$Bin/../foo";

my $fs = DBI::Filesystem->new($dsn,{initialize=>0});
#my $fs = DBI::Filesystem->new($dsn);
$fs->mount($mnt);

exit 0;
