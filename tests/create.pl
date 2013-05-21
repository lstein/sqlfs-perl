#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

my $fs = DBI::Filesystem->new('dbi:mysql:filesystem;user=lstein;password=blah',1);
$fs->create_directory('foo');
$fs->create_directory('/one');
$fs->create_directory('/one/subdirectory_one');
$fs->create_directory('/two');
$fs->create_directory('/two/subdirectory_two');
$fs->create_directory('/two/subdirectory_two/subdirectory_two_two');
$fs->create_directory('/three');
$fs->create_file('/foo.mpg');
$fs->create_file('/one/foo.mpg');
$fs->create_file('/one/bar.mpg');
$fs->create_file('/two/subdirectory_two/subdirectory_two_two/deep.mpg');

print join ',',$fs->entries('/'),"\n";
print join ',',$fs->entries('/one'),"\n";
print join ',',$fs->entries('/one/'),"\n";
print join ',',$fs->entries('/one/subdirectory_one'),"\n";
print join ',',$fs->entries('/two/subdirectory_two/subdirectory_two_two'),"\n";
my @stat = $fs->stat('/two/subdirectory_two/subdirectory_two_two/deep.mpg');
print join(",",@stat),"\n";

$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg','this old man had a frog in his throat',0);
$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg',' and more is here',37);
my $length = ($fs->stat('/two/subdirectory_two/subdirectory_two_two/deep.mpg'))[7];
$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg','this should have two zeroes interpolated',$length+2);
$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg',scalar('.'x(4096*2+10)),96);
print $fs->read('/two/subdirectory_two/subdirectory_two_two/deep.mpg',10,0),"\n";
print $fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg','everyone',5),"\n";

print eval{$fs->remove_dir('/one/subdirectory_one')},"\n";
print eval{$fs->remove_dir('/two/subdirectory_two')},"\n";
print eval{$fs->unlink_file('/two/subdirectory_two')},"\n";
print eval{$fs->unlink_file('/two/subdirectory_two/subdirectory_two_two/deep.mpg')},"\n";
print eval{$fs->remove_dir('/two/subdirectory_two/subdirectory_two_two')},"\n";
print eval{$fs->remove_dir('/two/subdirectory_two')},"\n";

1;
exit 0;
