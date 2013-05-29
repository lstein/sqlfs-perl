package DBI::Filesystem::Pg;

use strict;
use warnings;
use base 'DBI::Filesystem';

sub _metadata_table_def {
    return <<END;
create table metadata (
    inode        serial       primary key,
    mode         integer      not null,
    uid          integer      not null,
    gid          integer      not null,
    links        integer      default 0,
    inuse        integer      default 0,
    length       bigint       default 0,
    mtime        timestamp,
    ctime        timestamp,
    atime        timestamp
)
END
}

sub _path_table_def {
    return <<END;
create table path (
    inode        integer      not null,
    name         varchar(255) not null,
    parent       integer
);
    create unique index ipath on path (parent,name)
END
}

sub _data_table_def {
    return <<END;
create table data (
    inode        integer,
    block        integer,
    contents     bytea
);
    create unique index iblock on data (inode,block)
END
}

sub _get_unix_timestamp_sql {
    my $self  = shift;
    my $field = shift;
    return "extract(epoch from $field)";
}

sub _now_sql {
    return "'now'";
}

sub _update_utime_sql {
    return "update metadata set atime=to_timestamp(?),mtime=to_timestamp(?) where inode=?";
}

1;

