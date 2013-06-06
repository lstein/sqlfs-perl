#-*-Perl-*-

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

use strict;
use FindBin '$Bin';
use lib $Bin,"$Bin/../lib";

use Test::More;
use File::Temp;
use POSIX qw(ENOENT EISDIR ENOTDIR EINVAL ENOTEMPTY EACCES EIO 
             O_RDONLY O_WRONLY O_RDWR F_OK R_OK W_OK X_OK);
use select_dsn;

$SIG{INT}=$SIG{TERM}=sub {exit 0 };
my ($child,$pid,$mtpt);

my @dsn = all_dsn();
plan tests => 1+ (4 * @dsn);

use_ok('DBI::Filesystem');
for my $dsn (@dsn) {
    diag("Testing with $dsn") if $ENV{HARNESS_VERBOSE};

    system "fusermount -u $mtpt 2>/dev/null" if $mtpt;

    my $fs = DBI::Filesystem->new($dsn,{initialize=>1}) 
	or BAIL_OUT("failed to obtain a filesystem object");

    $mtpt = File::Temp->newdir();
    
    $child = fork();
    defined $child or BAIL_OUT("fork failed: $!");
    if (!$child) {
	$fs->mount($mtpt,{mountopts=>'fsname=sqlfs'});
	exit 0;
    }

    wait_for_mount($mtpt,20) or BAIL_OUT("didn't see mountpoint appear");
    ok(1,'mountpoint appears');
    
    umask 002;
    ok(mkdir("$mtpt/dir1"),'mkdir');
    ok(-d "$mtpt/dir1",'directory exists');
    my @stat = stat("$mtpt/dir1");
    is($stat[2],040775,'stat correct');
}

exit 0;

END {
    system "fusermount -u $mtpt 2>/dev/null" if $mtpt;
    kill TERM=>$pid if $pid;
}

sub wait_for_mount {
    my ($mtpt,$timeout) = @_;
    local $SIG{ALRM} = sub {die "timeout"};
    alarm($timeout);
    eval {
	while (1) {
	    my $df = `df $mtpt`;
	    last if $df =~ /^sqlfs/m;
	    sleep 1;
	}
	alarm(0);
    };
    return 1 unless $@;
}
