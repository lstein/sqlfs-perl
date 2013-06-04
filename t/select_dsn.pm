package select_dsn;
use base Exporter;
our @EXPORT = 'find_dsn';

use strict;
use warnings;
use DBI;

my %drivers = map {$_=>1} DBI->available_drivers;



1;
