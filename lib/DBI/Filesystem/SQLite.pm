package DBI::Filesystem::SQLite;

use strict;
use warnings;
use base 'DBI::Filesystem';

sub blocksize   { return 16384 }
sub flushblocks { return   256 }

sub _metadata_table_def {
    return <<END;
create table metadata (
    inode        integer      primary key autoincrement,
    mode         int(10)      not null,
    uid          int(10)      not null,
    gid          int(10)      not null,
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

sub _data_table_def {
    return <<END;
create table data (
    inode        int(10),
    block        int(10),
    contents     blob
);
    create unique index iblock on data (inode,block)
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

