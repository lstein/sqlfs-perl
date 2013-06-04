package select_dsn;
use base Exporter;
our @EXPORT = 'find_dsn';

use strict;
use warnings;
use File::Temp;
use DBI;

our $tmpdir;

sub find_dsn {
    return $ENV{TEST_DSN} if $ENV{TEST_DSN};

    my %drivers = map {$_=>1} DBI->available_drivers;
    my $dsn;
    foreach (qw(SQLite mysql Pg)) {
	next unless $drivers{$_};
	$dsn ||= select_dsn->$_;
    }
    return $ENV{TEST_DSN} = $dsn;
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
    my $dsn  = "dbi:mysql:database=test;user=anonymous";
    my $dbh  = DBI->connect($dsn,undef,undef,{PrintError=>0}) or return;
    return $dsn;
}

sub Pg {
    my $self = shift;
    my $dsn  = "dbi:Pg:database=postgres";
    my $dbh  = DBI->connect($dsn,undef,undef,{PrintError=>0}) or return;
    return $dsn;
}



1;
