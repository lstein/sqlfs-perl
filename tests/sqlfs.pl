#!/usr/bin/perl

use strict;
use FindBin '$Bin';
use lib "$Bin/../lib";
use DBI::Filesystem;
use POSIX qw(SIGINT);

my $dsn = shift || 'dbi:mysql:filesystem;user=lstein;password=blah';
my $mnt = shift || "$Bin/../foo";

POSIX::sigaction(SIGINT,POSIX::SigAction->new(sub {warn "bye bye"; exec 'fusermount','-u',$mnt}))
    || die "Couldn't set SIGINT: $!";
#$SIG{INT} = sub {warn "bye bye"; exec 'fusermount','-u',$mnt};

my $fs = DBI::Filesystem->new($dsn,{create=>0});
#my $fs = DBI::Filesystem->new($dsn);
$fs->mount($mnt,{mountopts=>'suid,noatime,allow_other,dev,suid',debug=>0});

exit 0;
