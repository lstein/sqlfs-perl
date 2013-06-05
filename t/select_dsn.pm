package select_dsn;
use base Exporter;
our @EXPORT = qw(first_dsn all_dsn);

use strict;
use warnings;
use File::Temp;
use DBI;

our $tmpdir;

sub all_dsn {
    return split /\s+/,$ENV{TEST_DSN} if $ENV{TEST_DSN};
    my @result;

    my %drivers = map {$_=>1} DBI->available_drivers;
    foreach (qw(SQLite mysql Pg)) {
	next unless $drivers{$_};
	my $dsn =select_dsn->$_ or next;
	push @result,$dsn;
    }
    $ENV{TEST_DSN} = join ' ',@result;
    return @result;
}

sub first_dsn {
    my @dsn = all_dsn() or return;
    return $dsn[0];
}

sub SQLite {
    my $self = shift;
    $tmpdir  = File::Temp->newdir();
    my $testfile = "$tmpdir/filesystem.sql";
    my $dsn      = "dbi:SQLite:dbname=$testfile";
    my $dbh      = DBI->connect($dsn,undef,undef,{PrintError=>0}) or return;
    return $dsn;
}

sub mysql {
    my $self = shift;
    my $dsn  = "dbi:mysql:dbname=test;user=anonymous";
    my $dbh  = DBI->connect($dsn,undef,undef,{PrintError=>0}) or return;
    return $dsn;
}

sub Pg {
    my $self = shift;
    my $dsn  = "dbi:Pg:dbname=postgres";
    my $dbh  = DBI->connect($dsn,undef,undef,{PrintError=>0}) or return;
    return $dsn;
}



1;
