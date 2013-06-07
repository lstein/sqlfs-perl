package DBI::Filesystem::DBD::SQLite;

use strict;
use warnings;
use base 'DBI::Filesystem';
use File::Temp;

# this method provides a DSN used by ./Build test
sub test_dsn {
    my $self = shift;
    our $tmpdir  = File::Temp->newdir();
    my $testfile = "$tmpdir/filesystem.sql";
    my $dsn      = "dbi:SQLite:dbname=$testfile";
}

#sub blocksize   { return 16384 }
sub flushblocks { return   256 }

# called after database handle is first created to do extra preparation on it
sub _dbh_init {
    my $self = shift;
    my $dbh = shift;
    $dbh->do('PRAGMA synchronous = OFF');
}

sub _metadata_table_def {
    return <<END;
create table metadata (
    inode        integer      primary key autoincrement,
    mode         int(10)      not null,
    uid          int(10)      not null,
    gid          int(10)      not null,
    rdev         int(10)      default 0,
    links        int(10)      default 0,
    inuse        int(10)      default 0,
    length       bigint       default 0,
    mtime        integer,
    ctime        integer,
    atime        integer
)
END
}

sub _path_table_def {
    return <<END;
create table path (
    inode        int(10)      not null,
    name         varchar(255) not null,
    parent       int(10)
);
    create unique index ipath on path (parent,name)
END
}

sub _extents_table_def {
    return <<END;
create table extents (
    inode        int(10),
    block        int(10),
    contents     blob
);
    create unique index iblock on extents (inode,block)
END
}

sub _get_unix_timestamp_sql {
    my $self  = shift;
    my $field = shift;
    return $field;
}

sub _now_sql {
    return "strftime('%s','now')";
}

sub _update_utime_sql {
    return "update metadata set atime=?,mtime=? where inode=?";
}

1;

