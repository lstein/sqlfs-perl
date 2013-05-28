package DBI::Filesystem::SQLite;

use strict;
use warnings;
use base 'DBI::Filesystem';

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

sub _fstat_sql {
    my $self  = shift;
    my $inode = shift;
    return <<END;
select n.inode,mode,uid,gid,links,
       ctime,mtime,atime,length
 from metadata as n
 left join data as c on (n.inode=c.inode)
 where n.inode=$inode
END
}

sub _timestamp_sql {
    return "strftime('%s','now')";
}

sub _create_inode_sql {
    my $self = shift;
    my $now = $self->_timestamp_sql;
    return "insert into metadata (mode,uid,gid,links,mtime,ctime,atime) values(?,?,?,?,$now,$now,$now)";
}

sub _update_utime_sql {
    return "update metadata set atime=?,mtime=?";
}

1;

