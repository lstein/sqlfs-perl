package DBI::Filesystem::DBD::Pg;

use strict;
use warnings;
use base 'DBI::Filesystem';
use DBD::Pg 'PG_BYTEA';

# this provides a DSN used during automatic testing by ./Build test
sub test_dsn {
    return "dbi:Pg:dbname=postgres";
}

# called after database handle is first created to do extra preparation on it
sub _dbh_init {
    my ($self,$dbh) = @_;
    $dbh->do('set client_min_messages to WARNING');
}

sub _metadata_table_def {
    return <<END;
create table metadata (
    inode        serial       primary key,
    mode         integer      not null,
    uid          integer      not null,
    gid          integer      not null,
    rdev         integer      default 0,
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

sub _extents_table_def {
    return <<END;
create table extents (
    inode        integer,
    block        integer,
    contents     bytea
);
    create unique index iblock on extents (inode,block)
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

sub _write_blocks {
    my $self = shift;
    my ($inode,$blocks,$blksize) = @_;

    my $dbh = $self->dbh;
    my ($length) = $dbh->selectrow_array("select length from metadata where inode=$inode");
    my $hwm      = $length;  # high water mark ;-)

    eval {
	$dbh->begin_work;
	my $insert = $dbh->prepare_cached(<<END) or die $dbh->errstr;
insert into extents (inode,block,contents) values (?,?,?)
END
;
	$insert->bind_param(3,undef,{pg_type=>PG_BYTEA});

	my $update = $dbh->prepare_cached(<<END) or die $dbh->errstr;
update extents set contents=? where inode=? and block=?
END
;
	$update->bind_param(1,undef,{pg_type=>PG_BYTEA});


	for my $block (keys %$blocks) {
	    my $data = $blocks->{$block};
	    $update->execute($data,$inode,$block);
	    $insert->execute($inode,$block,$data) unless $update->rows;
	    my $a   = $block * $blksize + length($data);
	    $hwm    = $a if $a > $hwm;
	}
	$insert->finish;
	$update->finish;
	my $now = $self->_now_sql;
	$dbh->do("update metadata set length=$hwm,mtime=$now where inode=$inode");
	$dbh->commit();
    };

    if ($@) {
	my $msg = $@;
	eval{$dbh->rollback()};
	warn $msg;
	die "write failed with $msg";
    }

    1;
}

sub last_inserted_inode {
    my $self = shift;
    my $dbh  = shift;
    return $dbh->last_insert_id(undef,undef,'metadata','inode');
}

1;

