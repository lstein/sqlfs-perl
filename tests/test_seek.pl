#!/usr/bin/perl

use strict;
use IO::File;
use FindBin '$Bin';

chdir "$Bin/..";
-e 'foo' or die "no filesystem mounted";
system "touch foo/bar.txt";
my $fh = IO::File->new('+<foo/bar.txt') or die $!;
print $fh "george was a dragon\n";
# $fh->flush;
$fh->seek(0,0);
print <$fh>;
$fh->seek(0,0);
print $fh "brenda";
$fh->seek(0,0);
print <$fh>;
close $fh;

