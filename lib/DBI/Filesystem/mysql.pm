package DBI::Filesystem::mysql;

use base 'DBI::Filesystem';

sub _metadata_table_def {
    return <<END;
create table metadata (
    inode        int(10)      auto_increment primary key,
    mode         int(10)      not null,
    uid          int(10)      not null,
    gid          int(10)      not null,
    links        int(10)      default 0,
    inuse        int(10)      default 0,
    length       bigint       default 0,
    mtime        timestamp    default 0,
    ctime        timestamp    default 0,
    atime        timestamp    default 0
) ENGINE=INNODB
END
}

sub _path_table_def {
    return <<END;
create table path (
    inode        int(10)      not null,
    name         varchar(255) not null,
    parent       int(10),
    index path (parent,name)
) ENGINE=INNODB
END
}

sub _data_table_def {
    return <<END;
create table data (
    inode        int(10),
    block        int(10),
    contents     blob,
    unique index iblock (inode,block)
) ENGINE=MYISAM
END
}

sub _get_unix_timestamp_sql {
    my $self  = shift;
    my $field = shift;
    return "unix_timestamp($field)";
}

sub _now_sql {
    return 'now()';
}

sub _update_utime_sql {
    return "update metadata set atime=from_unixtime(?),mtime=from_unixtime(?) where inode=?";
}

1;

