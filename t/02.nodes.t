#-*-Perl-*-

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

use strict;
use FindBin '$Bin';
use lib $Bin,"$Bin/../lib";

use Test::More;
use POSIX qw(ENOENT EISDIR ENOTDIR EINVAL ENOTEMPTY EACCES EIO);
use select_dsn;

my $dsn = find_dsn();
if ($dsn) {
   plan tests => 16;
} else {
  plan skip_all => 'could not find a usable database source';
}

use_ok('DBI::Filesystem');
my $fs = DBI::Filesystem->new($dsn,{initialize=>1}) 
    or BAIL_OUT("failed to obtain a filesystem object");

# directories
ok($fs->mkdir('a'),     'directory create 1');
ok($fs->mkdir('a/1'),   'directory create 2');
ok($fs->mkdir('a/1/i'), 'directory create 3');
ok($fs->mkdir('a/1/ii'),'directory create 4');

eval {$fs->mkdir('a/2/i')};
like($@,qr{a/2 not found},'cannot create path if parent directory nonexistent');

ok($fs->mkdir('a/2'),   'directory create 5');
ok($fs->mkdir('a/2/i'), 'directory create 6');
ok($fs->mkdir('a/2/ii'),'directory create 7');
ok($fs->mkdir('b'),     'directory create 8');
ok($fs->mkdir('b/1'),   'directory create 9');
ok($fs->mkdir('b/1/i'), 'directory create 10');
ok($fs->mkdir('b/1/ii'),'directory create 11');
ok($fs->mkdir('b/2'),   'directory create 12');
ok($fs->mkdir('b/2/i'), 'directory create 13');
ok($fs->mkdir('b/2/ii'),'directory create 14');

ok($fs->mknod('a/file1.txt'),    'file create 1');
ok($fs->mknod('a/file2.txt'),    'file create 2');
ok($fs->mknod('a/1/i/file3.txt'),'file create 3');
ok($fs->mknod('a/1/i/file4.txt'),'file create 4');

eval {$fs->mknod('c/file3.txt')};
like($@,qr{c not found},'cannot create file if parent directory nonexistent');

eval {$fs->mknod('a/file1.txt')};
# warn $@;
