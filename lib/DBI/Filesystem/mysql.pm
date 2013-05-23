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
    mtime        timestamp,
    ctime        timestamp,
    atime        timestamp
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

1;

