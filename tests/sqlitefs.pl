#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

my $dsn = shift || 'dbi:SQLite:/home/lstein/projects/sqlfs-perl/sqlite.sql';
my $mnt = shift || "$Bin/../foo";

my $fs = DBI::Filesystem->new($dsn,{initialize=>1});
#my $fs = DBI::Filesystem->new($dsn);
$fs->mount($mnt,{mountopts=>'fsname=sqlfs'});

exit 0;
