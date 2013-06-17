#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

my $fs = DBI::Filesystem->new('dbi:mysql:filesystem;user=lstein;password=blah',
			      {initialize=>1,allow_magic_dirs=>1});
$fs->mkdir('/%%small_files');
$fs->mknod('/%%small_files/.query');
$fs->write('/%%small_files/.query','select inode from metadata where size <10');
$fs->mknod('/foo.mpg');
$fs->mknod('/bar.mpg');
$fs->mknod('/big.mpg');
$fs->write('/big.mpg','this contains more than 10 letters!');
$fs->flush();

my @entries = $fs->getdir('%%small_files');
print join "\n",@entries,"\n";

1;
exit 0;
