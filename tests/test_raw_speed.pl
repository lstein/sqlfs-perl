#!/usr/bin/perl

use strict;
use warnings;
use DBI;
#my $dbh = DBI->connect('dbi:mysql:filesystem;user=lstein;password=blah') or die;
my $dbh = DBI->connect('dbi:SQLite:/home/lstein/projects/sqlfs-perl/sqlite.sql');
$dbh->{RaiseError} = 1;
# $dbh->do('delete from data');
my $sth = $dbh->prepare('replace into data values (?,?,?)');
my $buffer;
my $block=0;
warn "starting write...";
eval {
    $dbh->begin_work();
    while (read(\*STDIN,$buffer,4096)) {
	$sth->execute(100,$block++,$buffer);
    }
    warn "committing...";
    $dbh->commit();
};

if ($@) {
    warn "commit failed with $@. Rolling back.";
    eval {$dbh->rollback()};
}
$sth->finish;

