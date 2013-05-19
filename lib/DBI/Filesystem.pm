package DBI::Filesystem;

=head1 NAME

DBI::Filesystem - Store a filesystem in a relational database

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=head1 AUTHOR

Copyright 2013, Lincoln D. Stein <lincoln.stein@gmail.com>

=head1 LICENSE

This package is distributed under the terms of the Perl Artistic
License 2.0. See http://www.perlfoundation.org/artistic_license_2_0.

=cut

use strict;
use warnings;
use DBI;
use Fuse;
use threads;
use threads::shared;
use File::Basename 'basename','dirname';
use File::Spec;
use POSIX qw(ENOENT EISDIR ENOTDIR ENOTEMPTY EINVAL ECONNABORTED EACCES EIO);
use Carp 'croak';

sub new {
    my $class = shift;
    my ($dsn,$create) = @_;
    my $self  = bless {dsn=>$dsn},ref $class || $class;
    $self->_initialize_schema if $create;
    return $self;
}

############### filesystem handlers below #####################

my $Self;   # because entrypoints cannot be passed as closures

sub mount {
    my $self = shift;
    my $mtpt = shift or croak "Usage: mount(\$mountpoint)";

    my $pkg  = __PACKAGE__;

    $Self = $self;  # because entrypoints cannot be passed as closures
    Fuse::main(mountpoint => $mtpt,
	       mountopts  => '',
	       getdir     => "$pkg\:\:e_getdir",
	       getattr    => "$pkg\:\:e_getattr",
	       read       => "$pkg\:\:e_read",
	       write      => "$pkg\:\:e_write",
	       truncate   => "$pkg\:\:e_truncate",
	       mknod      => "$pkg\:\:e_mknod",
	       mkdir      => "$pkg\:\:e_mkdir",
	       rmdir      => "$pkg\:\:e_rmdir",
	       link       => "$pkg\:\:e_link",
	       unlink     => "$pkg\:\:e_unlink",
	       utime      => "$pkg\:\:e_utime",
	       threaded   => 0,
	);
}

sub fixup {
    my $path = shift;
    $path    =~ s!^/!!;
    $path   || '/';
}

sub e_getdir {
    my $path = fixup(shift);
    my @entries = eval {$Self->entries($path)};
    return -ENOENT()  if $@ =~ /not found/;
    return -ENOTDIR() if $@ =~ /not directory/;
    return (@entries,0);
}

sub e_getattr {
    my $path  = fixup(shift);
    my @stat  = eval {$Self->stat($path)};
    return -ENOENT()  if $@ =~ /not found/;
    return @stat;
}

sub e_mkdir {
    my $path = fixup(shift);
    my $mode = shift;
    eval {$Self->create_directory($path,$mode,0,0)};
    return -ENOENT() if $@ =~ /not found/;
    0;
}

sub e_mknod {
    my $path = fixup(shift);
    my ($mode,$device) = @_;
    eval {$Self->create_file($path,$mode,0,0)};
    return -ENOENT() if $@ =~ /not found/;
    0;
}

sub e_read {
    my ($path,$size,$offset) = @_;
    $path    = fixup($path);
    my $data = eval {$Self->read($path,$size,$offset)};
    return -ENOENT()  if $@ =~ /not found/;
    return -EISDIR()  if $@ =~ /is a directory/;
    return $data;
}

sub e_write {
    my ($path,$buffer,$size,$offset) = @_;
    $path    = fixup($path);
    my $data = eval {$Self->write($path,$buffer,$size,$offset)};
    return -ENOENT()  if $@ =~ /not found/;
    return -EISDIR()  if $@ =~ /is a directory/;
    return $data;
}

sub e_truncate {
    my ($path,$offset) = @_;
    $path = fixup($path);
    eval {$Self->truncate($path,$offset)};
    return -ENOENT()  if $@ =~ /not found/;
    return -EISDIR()  if $@ =~ /is a directory/;
    return -EINVAL()  if $@ =~ /length beyond end of file/;
    return 0;
}

sub e_link {
    my ($oldname,$newname) = @_;
    eval {$Self->create_hardlink($oldname,$newname)};
    return -ENOENT()  if $@ =~ /not found/;
    return -ENOTDIR() if $@ =~ /invalid directory/;
    return 0;
}

sub e_unlink {
    my $path = shift;
    eval {$Self->unlink_file($path)};
    return -ENOENT()  if $@ =~ /not found/;
    return -EISDIR() if $@ =~ /is a directory/;
    0;
}

sub e_rmdir {
    my $path = shift;
    eval {$Self->remove_dir($path)};
    return -ENOENT()    if $@ =~ /not found/;
    return -ENOTDIR()   if $@ =~ /not a directory/;
    return -ENOTEMPTY() if $@ =~ /not empty/;
    0;
}

sub e_utime {
    my ($path,$atime,$mtime) = @_;
    $path = fixup($path);
    my $result = eval {$Self->utime($path,$atime,$mtime)};
    return -ENOENT()  if $@ =~ /not found/;
    return -EIO()     unless $result;
    return 0;
}

########################### DBI methods below ######################

sub dsn { shift->{dsn} }
sub dbh {
    my $self = shift;
    my $dsn  = $self->dsn;
    return $self->{dbh} ||= DBI->connect($dsn,
					 undef,undef,
					 {RaiseError=>1,
					  AutoCommit=>1}) or croak DBI->errstr;
}

sub create_inode {
    my $self        = shift;
    my ($type,$mode,$uid,$gid) = @_;

    $mode  = 0777 unless defined $mode;
    $mode |=  $type eq 'f' ? 0100000
             :$type eq 'd' ? 0040000
                           : 0100000;  # default
    $uid ||= 0;
    $gid ||= 0;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare("insert into metadata (mode,uid,gid,mtime,ctime,atime) values(?,?,?,null,null,null)");
    $sth->execute($mode,$uid,$gid) or die $sth->errstr;
    $sth->finish;
    return $dbh->last_insert_id(undef,undef,undef,undef);
}

sub create_hardlink {
    my $self = shift;
    my ($oldpath,$newpath) = @_;
    my $inode  = $self->path2inode($oldpath);
    $self->create_path($inode,$newpath);
}

# this links an inode to a path
sub create_path {
    my $self = shift;
    my ($inode,$path) = @_;

    my $dir    = dirname($path);
    $dir       = '/' if $dir eq '.'; # work around funniness in dirname()
    my $parent = $self->path2inode($dir) or die "invalid directory";

    my $base   = basename($path);
    $base      =~ s!/!_!g;

    my $dbh  = $self->dbh;
    my $sth  = $dbh->prepare('insert into path (inode,name,parent) values (?,?,?)');
    $sth->execute($inode,$base,$parent)           or die $sth->errstr;
    $sth->finish;

    $dbh->do("update metadata set links=links+1 where inode=$inode");
}

sub create_inode_and_path {
    my $self = shift;
    my ($path,$type,$mode,$uid,$gid) = @_;
    my $dbh    = $self->dbh;
    my $inode;
    eval {
	$dbh->begin_work;
	$inode  = $self->create_inode($type,$mode,$uid,$gid);
	$self->create_path($inode,$path);
	$dbh->commit;
    };
    $dbh->rollback() if $@;
    return $inode;
}

sub create_file { 
    my $self = shift;
    my ($path,$mode,$uid,$gid) = @_;
    $self->create_inode_and_path($path,'f',$mode,$uid,$gid);
}

sub create_directory {
    my $self = shift;
    my ($path,$mode,$uid,$gid) = @_;    
    $self->create_inode_and_path($path,'d',$mode,$uid,$gid);
}

sub unlink_file {
    my $self  = shift;
    my $path  = shift;
    my ($inode,$parent,$name)  = $self->path2inode($path) ;

    $parent ||= 1;
    $name   ||= basename($path);

    $self->_isdir($inode)               and croak "$path is a directory";
    my $dbh                    = $self->dbh;
    my $sth                    = $dbh->prepare("delete from path where inode=? and parent=? and name=?") 
	or die $dbh->errstr;
    $sth->execute($inode,$parent,$name) or die $dbh->errstr;

    $dbh->do("update metadata set links=links-1 where inode=$inode");
    my ($links,$inuse) = $dbh->selectrow_array("select links,inuse from metadata where inode=$inode");
    if ($links <=0 && $inuse<=0) {
	$dbh->do("delete from metadata where inode=$inode") or die $dbh->errstr;
    }
}

sub remove_dir {
    my $self = shift;
    my $path  = shift;
    my $inode = $self->path2inode($path) ;
    $self->_isdir($inode)                or croak "$path is not a directory";
    $self->_entries($inode )            and croak "$path is not empty";

    my $dbh   = $self->dbh;
    $dbh->do("delete from path where inode=$inode") or die $dbh->errstr;
}    

sub chown {
    my $self         = shift;
    my ($path,$uid)  = @_;
    my $inode        = $self->path2inode($path) ;
    my $dbh          = $self->dbh;
    return $dbh->do("update metadata set uid=$uid where inode=$inode");
}

sub chgrp {
    my $self         = shift;
    my ($path,$gid)  = @_;
    my $inode        = $self->path2inode($path) ;
    my $dbh          = $self->dbh;
    return $dbh->do("update metadata set gid=$gid where inode=$inode");
}

sub chmod {
    my $self         = shift;
    my ($path,$mode) = @_;
    my $inode        = $self->path2inode($path) ;
    my $dbh          = $self->dbh;
    return $dbh->do("update metadata set mode=((0xf000&mode)|$mode) where inode=$inode");
}

sub stat {
    my $self         = shift;
    my $path         = shift;
    my $inode        = $self->path2inode($path);
    my $dbh          = $self->dbh;
    my ($ino,$mode,$uid,$gid,$nlinks,$ctime,$mtime,$atime,$size) =
	$dbh->selectrow_array(<<END);
select n.inode,mode,uid,gid,links,
       unix_timestamp(ctime),unix_timestamp(mtime),unix_timestamp(atime),
       if(isnull(contents),0,length(contents))
 from metadata as n
 left join data as c on (n.inode=c.inode)
 where n.inode=$inode
END
;
    $ino or die $dbh->errstr;

    my $dev     = 0;
    my $blksize = 1024;
    my $blocks  = 1;
    return ($dev,$ino,$mode,$nlinks,$uid,$gid,0,$size,$atime,$mtime,$ctime,$blksize,$blocks);
}

sub read {
    my $self = shift;
    my ($path,$length,$offset) = @_;

    my $inode  = $self->path2inode($path);
    $self->_isdir($inode) and croak "$path is a directory";
    my $dbh    = $self->dbh;
    $offset  ||= 0;
    $offset++;  # sql uses 1-based string indexing
    my ($data) = $dbh->selectrow_array("select substring(contents,$offset,$length) from data where inode=$inode");
    return $data;
}

sub write {
    my $self = shift;
    my ($path,$data,$offset) = @_;

    my $inode  = $self->path2inode($path);
    $self->_isdir($inode) and croak "$path is a directory";

    my $dbh    = $self->dbh;
    $offset  ||= 0;

    # check that offset isn't greater than current position
    my @stat   = $self->stat($path);
    $stat[7] >= $offset or croak "offset beyond end of file";

    my $sth = $dbh->prepare(<<END) or die $dbh->errstr;
insert into data (inode,contents) values (?,?)
 on duplicate key update contents=insert(contents,?,?,?)
END
;
    $sth->execute($inode,$data,$offset+1,length($data),$data) or die $dbh->errstr;
    $self->_touch($inode);
    1;
}

sub truncate {
    my $self = shift;
    my ($path,$length) = @_;

    my $inode = $self->path2inode($path);
    $self->_isdir($inode) and croak "$path is a directory";

    my $dbh    = $self->dbh;
    $length  ||= 0;

    # check that length isn't greater than current position
    my @stat   = $self->stat($path);
    $stat[7] >= $length or croak "length beyond end of file";

    my $sth = $dbh->prepare(<<END) or die $dbh->errstr;
update data set contents=substr(contents,1,?) where inode=?
END
;

    $sth->execute($length,$inode) or die $dbh->errstr;
    $self->_touch($inode);
    1;
}

sub isdir {
    my $self = shift;
    my $path = shift;
    my $inode = $self->path2inode($path) ;
    return $self->_isdir($inode);
}

sub _isdir {
    my $self  = shift;
    my $inode = shift;
    my $dbh   = $self->dbh;
    my ($result) = $dbh->selectrow_array("select (0xf000&mode)=0x4000 from metadata where inode=$inode")
	or die $dbh->errstr;
    return $result;
}

sub touch {
    my $self = shift;
    my $path = shift;
    my $inode = $self->path2inode($path) ;
    $self->_touch($inode);
}

sub _touch {
    my $self  = shift;
    my $inode = shift;
    my $dbh   = $self->dbh;
    $dbh->do("update metadata set mtime=now() where inode=$inode");
}

sub utime {
    my $self = shift;
    my ($path,$atime,$mtime) = @_;
    my $inode = $self->path2inode($path) ;
    my $dbh    = $self->dbh;
    my $sth    = $dbh->prepare("update metadata set atime=from_unixtime(?),mtime=from_unixtime(?)");
    my $result = $sth->execute($atime,$mtime);
    $sth->finish();
    return $result;
}

sub entries {
    my $self = shift;
    my $path = shift;
    my $inode = $self->path2inode($path) ;
    $self->_isdir($inode) or croak "not directory";
    return $self->_entries($inode);
}

sub _entries {
    my $self  = shift;
    my $inode = shift;
    my $dbh   = $self->dbh;
    my $col   = $dbh->selectcol_arrayref("select name from path where parent=$inode");
    return @$col;
}

# in scalar context return inode
# in list context return (inode,parent_inode,name)
sub path2inode {
    my $self   = shift;
    my $path   = shift;
    if ($path eq '/') {
	return wantarray ? (1,undef,'/') : 1;
    }
    $path =~ s!/$!!;
    my ($sql,@bind) = $self->_path2inode_sql($path);
    my $dbh    = $self->dbh;
    my $sth    = $dbh->prepare($sql) or croak $dbh->errstr;
    $sth->execute(@bind);
    my @v      = $sth->fetchrow_array() or croak "$path not found";
    $sth->finish;
    return wantarray ? @v : $v[0];
}

sub _path2inode_sql {
    my $self   = shift;
    my $path   = shift;
    my (undef,$dir,$name) = File::Spec->splitpath($path);
    my ($parent,@base)    = $self->_path2inode_subselect($dir); # something nicely recursive
    my $sql               = <<END;
select p.inode,p.parent,p.name from metadata as m,path as p 
       where p.name=? and p.parent in ($parent) 
         and m.inode=p.inode
END
;
    return ($sql,$name,@base);
}

sub _path2inode_subselect {
    my $self = shift;
    my $path = shift;
    return 'select 1' if $path eq '/' or !length($path);
    $path =~ s!/$!!;
    my (undef,$dir,$name) = File::Spec->splitpath($path);
    my ($parent,@base)    = $self->_path2inode_subselect($dir); # something nicely recursive
    return (<<END,$name,@base);
select p.inode from metadata as m,path as p
    where p.name=? and p.parent in ($parent)
    and m.inode=p.inode
END
}

sub _initialize_schema {
    my $self = shift;
    my $dbh  = $self->dbh;
    $dbh->do('drop table if exists metadata') or croak $dbh->errstr;
    $dbh->do('drop table if exists path')     or croak $dbh->errstr;
    $dbh->do('drop table if exists data')     or croak $dbh->errstr;
    $dbh->do(<<END)                           or croak $dbh->errstr;
create table metadata (
    inode        int(10)      auto_increment primary key,
    mode         int(10)      not null,
    uid          int(10)      not null,
    gid          int(10)      not null,
    links        int(10)      default 0,
    inuse        int(10)      default 0,
    mtime        timestamp,
    ctime        timestamp,
    atime        timestamp
)
END
;
    $dbh->do(<<END)                       or croak $dbh->errstr;
create table path (
    inode        int(10)      not null,
    name         varchar(255) not null,
    parent       int(10),
    index path (parent,name)
)
END
    ;
    $dbh->do(<<END)                       or croak $dbh->errstr;
create table data (
    inode        int(10)      primary key,
    contents     longblob
)
END
;
    # create the root node
    # should update this to use fuse_get_context to get proper uid, gid and masked permissions
    my $mode = 0040000|0777;
    $dbh->do("insert into metadata (inode,mode,uid,gid,mtime,ctime,atime) values(1,$mode,0,0,null,null,null)") 
	or croak $dbh->errstr;
    $dbh->do("insert into path (inode,name,parent) values (1,'/',null)")
	or croak $dbh->errstr;
}

1;

__END__
