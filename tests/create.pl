#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;

#my $fs = DBI::Filesystem->new('dbi:mysql:filesystem;user=lstein;password=blah',{initialize=>1});
my $fs = DBI::Filesystem->new('dbi:CSV:f_dir=csv',{initialize=>1});
$fs->mkdir('foo');
$fs->mkdir('/one');
$fs->mkdir('/one/subdirectory_one');
$fs->mkdir('/two');
$fs->mkdir('/two/subdirectory_two');
$fs->mkdir('/two/subdirectory_two/subdirectory_two_two');
$fs->mkdir('/three');
$fs->mknod('/foo.mpg');
$fs->mknod('/one/foo.mpg');
$fs->mknod('/one/bar.mpg');
$fs->mknod('/two/subdirectory_two/subdirectory_two_two/deep.mpg');
$fs->link('/two/subdirectory_two/subdirectory_two_two/deep.mpg','/one/subdirectory_one/bar.mpg');
my $inode = $fs->path2inode('/two/subdirectory_two/subdirectory_two_two/deep.mpg');
my @paths = $fs->inode2paths($inode);
print join(',',@paths),"\n";

print join ',',$fs->getdir('/'),"\n";
print join ',',$fs->getdir('/one'),"\n";
print join ',',$fs->getdir('/one/'),"\n";
print join ',',$fs->getdir('/one/subdirectory_one'),"\n";
print join ',',$fs->getdir('/two/subdirectory_two/subdirectory_two_two'),"\n";
my @stat = $fs->getattr('/two/subdirectory_two/subdirectory_two_two/deep.mpg');
print join(",",@stat),"\n";

$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg','this old man had a frog in his throat',0);
$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg',' and more is here',37);
$fs->flush();
my $length = ($fs->getattr('/two/subdirectory_two/subdirectory_two_two/deep.mpg'))[7];
$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg','this should have two zeroes interpolated',$length+2);
$fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg',scalar('.'x(4096*2+10)),96);
$fs->flush();
print $fs->read('/two/subdirectory_two/subdirectory_two_two/deep.mpg',10,0),"\n";
print $fs->write('/two/subdirectory_two/subdirectory_two_two/deep.mpg','everyone',5),"\n";
$fs->flush();

print eval{$fs->remove_dir('/one/subdirectory_one')},"\n";
print eval{$fs->remove_dir('/two/subdirectory_two')},"\n";
print eval{$fs->unlink_file('/two/subdirectory_two')},"\n";
print eval{$fs->unlink_file('/two/subdirectory_two/subdirectory_two_two/deep.mpg')},"\n";
print eval{$fs->remove_dir('/two/subdirectory_two/subdirectory_two_two')},"\n";
print eval{$fs->remove_dir('/two/subdirectory_two')},"\n";

1;
exit 0;
