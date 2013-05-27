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
use Fuse 'fuse_get_context';
use threads;
use threads::shared;
use File::Basename 'basename','dirname';
use File::Spec;
use POSIX qw(ENOENT EISDIR ENOTDIR ENOTEMPTY EINVAL ECONNABORTED EACCES EIO EPERM
             O_RDONLY O_WRONLY O_RDWR O_CREAT F_OK R_OK W_OK X_OK
             S_IXUSR S_IXGRP S_IXOTH);
use Carp 'croak';
use Symbol 'gensym';
use IO::Handle;

use constant MAX_PATH_LEN => 4096;  # characters
use constant BLOCKSIZE    => 4096;  # bytes
use constant FLUSHBLOCKS  => 32;    # flush after we've accumulated this many cached blocks

my %Blockbuff :shared;

sub new {
    my $class = shift;
    my ($dsn,$create) = @_;
    my ($dbd)         = $dsn =~ /dbi:([^:]+)/;
    $dbd or croak "Could not figure out the DBI subclass to load from $dsn";
    my $subclass = __PACKAGE__.'::'.$dbd;
    eval "require $subclass;1" or croak $@  unless $subclass->can('new');
    my $self  = bless {dsn          => $dsn},$subclass;
    local $self->{dbh};  # to avoid cloning database handle into child threads
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
    Fuse::main(mountpoint  => $mtpt,
	       mountopts   => 'hard_remove,allow_other',
	       getdir      => "$pkg\:\:e_getdir",
	       getattr     => "$pkg\:\:e_getattr",
	       fgetattr    => "$pkg\:\:e_fgetattr",
	       open        => "$pkg\:\:e_open",
	       release     => "$pkg\:\:e_release",
	       read        => "$pkg\:\:e_read",
	       write       => "$pkg\:\:e_write",
	       truncate    => "$pkg\:\:e_truncate",
	       create      => "$pkg\:\:e_create",
	       mknod       => "$pkg\:\:e_mknod",
	       mkdir       => "$pkg\:\:e_mkdir",
	       rmdir       => "$pkg\:\:e_rmdir",
	       link        => "$pkg\:\:e_link",
	       rename      => "$pkg\:\:e_rename",
	       access      => "$pkg\:\:e_access",
	       chmod       => "$pkg\:\:e_chmod",
	       chown       => "$pkg\:\:e_chown",
	       symlink     => "$pkg\:\:e_symlink",
	       readlink    => "$pkg\:\:e_readlink",
	       unlink      => "$pkg\:\:e_unlink",
	       utime       => "$pkg\:\:e_utime",
	       nullpath_ok => 1,
	       debug       => 0,
	       threaded    => 1,
	);
}

sub fixup {
    my $path = shift;
    no warnings;
    $path    =~ s!^/!!;
    $path   || '/';
}

sub e_getdir {
    my $path = fixup(shift);
    my @entries = eval {$Self->getdir($path)};
    return $Self->errno($@) if $@;
    return (@entries,0);
}

sub e_getattr {
    my $path  = fixup(shift);
    my @stat  = eval {$Self->stat($path)};
    return $Self->errno($@) if $@;
    return @stat;
}

sub e_fgetattr {
    my ($path,$inode) = @_;
    my @stat  = eval {$Self->fstat(fixup($path),$inode)};
    return $Self->errno($@) if $@;
    return @stat;
}

sub e_mkdir {
    my $path = fixup(shift);
    my $mode = shift;
    my $ctx            = fuse_get_context;
    my $umask          = $ctx->{umask};
    eval {$Self->create_directory($path,$mode&(~$umask),$ctx->{uid},$ctx->{gid})};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_mknod {
    my $path = fixup(shift);
    my ($mode,$device) = @_;
    my $ctx            = fuse_get_context;
    my $umask          = $ctx->{umask};
    eval {$Self->create_file($path,$mode&(~$umask),$ctx->{uid},$ctx->{gid})};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_create {
    my $path = fixup(shift);
    my ($mode,$flags) = @_;
#    warn sprintf("create(%s,0%o,0%o)",$path,$mode,$flags);
    my $ctx            = fuse_get_context;
    my $umask          = $ctx->{umask};
    my $fh = eval {
	$Self->create_file($path,$mode&(~$umask),$ctx->{uid},$ctx->{gid});
	$Self->open($path,$flags,{},$ctx->{uid},$ctx->{gid});
    };
    return $Self->errno($@) if $@;
    return (0,$fh);
}

sub e_open {
    my ($path,$flags,$info) = @_;
#    warn sprintf("open(%s,0%o,%s)",$path,$flags,$info);
    $path    = fixup($path);
    my $fh = eval {$Self->open($path,$flags,$info)};
    return $Self->errno($@) if $@;
    (0,$fh);
}

sub e_release {
    my ($path,$flags,$fh) = @_;
    $Self->release($fh);
    return 0;
}
 

sub e_read {
    my ($path,$size,$offset,$fh) = @_;
    $path    = fixup($path);
    my $data = eval {$Self->read($path,$size,$offset,$fh)};
    return $Self->errno($@) if $@;
    return $data;
}

sub e_write {
    my ($path,$buffer,$offset,$fh) = @_;
    $path    = fixup($path);
    my $data = eval {$Self->write($path,$buffer,$offset,$fh)};
    return $Self->errno($@) if $@;
    return $data;
}

sub e_truncate {
    my ($path,$offset) = @_;
    $path = fixup($path);
    eval {$Self->truncate($path,$offset)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_link {
    my ($oldname,$newname) = @_;
    eval {$Self->create_hardlink($oldname,$newname)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_access {
    my ($path,$access_mode) = @_;
    eval {$Self->access($path,$access_mode)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_rename {
    my ($oldname,$newname) = @_;
    eval { 
	$Self->create_hardlink($oldname,$newname);
	$Self->unlink_file($oldname);
    };
    return $Self->errno($@) if $@;
    return 0;
}

sub e_chmod {
    my ($path,$mode) = @_;
    eval {$Self->chmod($path,$mode)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_chown {
    my ($path,$uid,$gid) = @_;
    eval {$Self->chown($path,$uid,$gid)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_symlink {
    my ($oldname,$newname) = @_;
    eval {$Self->create_symlink($oldname,$newname)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_readlink {
    my $path = shift;
    my $link = eval {$Self->read_symlink($path)};
    return $Self->errno($@) if $@;
    return $link;
}

sub e_unlink {
    my $path = shift;
    eval {$Self->unlink_file($path)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_rmdir {
    my $path = shift;
    eval {$Self->remove_dir($path)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_utime {
    my ($path,$atime,$mtime) = @_;
    $path = fixup($path);
    my $result = eval {$Self->utime($path,$atime,$mtime)};
    return $Self->errno($@) if $@;
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
             :$type eq 'l' ? 0120000
                           : 0100000;  # default
    $uid ||= 0;
    $gid ||= 0;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare_cached("insert into metadata (mode,uid,gid,links,mtime,ctime,atime) values(?,?,?,?,null,null,null)");
    $sth->execute($mode,$uid,$gid,$type eq 'd' ? 1 : 0) or die $sth->errstr;
    $sth->finish;
    return $dbh->last_insert_id(undef,undef,undef,undef);
}

sub create_hardlink {
    my $self = shift;
    my ($oldpath,$newpath) = @_;
    $self->check_perm(scalar $self->path2inode($self->_dirname($oldpath)),W_OK);
    $self->check_perm(scalar $self->path2inode($self->_dirname($newpath)),W_OK);
    my $inode  = $self->path2inode($oldpath);
    $self->create_path($inode,$newpath);
}

sub create_symlink {
    my $self = shift;
    my ($oldpath,$newpath) = @_;
    my $newnode= $self->create_inode_and_path($newpath,'l',0777);
    $self->write($newpath,$oldpath);
}

sub read_symlink {
    my $self   = shift;
    my $path   = shift;
    my $target = $self->read($path,MAX_PATH_LEN);
    return $target;
}

# this links an inode to a path
sub create_path {
    my $self = shift;
    my ($inode,$path) = @_;

    my $parent = $self->path2inode($self->_dirname($path));
    my $base   = basename($path);
    $base      =~ s!/!_!g;

    my $dbh  = $self->dbh;
    my $sth  = $dbh->prepare_cached('insert into path (inode,name,parent) values (?,?,?)');
    $sth->execute($inode,$base,$parent)           or die $sth->errstr;
    $sth->finish;

    $dbh->do("update metadata set links=links+1 where inode=$inode");
    $dbh->do("update metadata set links=links+1 where inode=$parent");
}

sub create_inode_and_path {
    my $self = shift;
    my ($path,$type,$mode) = @_;
    my $dbh    = $self->dbh;
    my $inode;

    my $parent = $self->path2inode($self->_dirname($path));
    $self->check_perm($parent,W_OK);

    my $ctx = fuse_get_context();

    eval {
	$dbh->begin_work;
	$inode  = $self->create_inode($type,$mode,@{$ctx}{'uid','gid'});
	$self->create_path($inode,$path);
	$dbh->commit;
    };
    if ($@) {
	warn "commit failed due to $@";
	eval{$dbh->rollback()};
    }
    return $inode;
}

sub create_file { 
    my $self = shift;
    my ($path,$mode,$uid,$gid) = @_;
    $self->create_inode_and_path($path,'f',$mode,$uid,$gid);
}

sub create_directory {
    my $self = shift;
    my ($path,$mode) = @_;
    $self->create_inode_and_path($path,'d',$mode);
}

sub unlink_file {
    my $self  = shift;
    my $path = shift;
    my ($inode,$parent,$name)  = $self->path2inode($path) ;

    $parent ||= 1;
    $self->check_perm($parent,W_OK);

    $name   ||= basename($path);

    $self->_isdir($inode)      and croak "$path is a directory";
    my $dbh                    = $self->dbh;
    my $sth                    = $dbh->prepare_cached("delete from path where inode=? and parent=? and name=?") 
	or die $dbh->errstr;
    $sth->execute($inode,$parent,$name) or die $dbh->errstr;

    $dbh->do("update metadata set links=links-1 where inode=$inode");
    $dbh->do("update metadata set links=links-1 where inode=$parent");
    $self->unlink_inode($inode);
}

sub unlink_inode {
    my $self = shift;
    my $inode = shift;
    my $dbh   = $self->dbh;
    my ($references) = $dbh->selectrow_array("select links+inuse from metadata where inode=$inode");
    return if $references > 0;
    eval {
	$dbh->begin_work;
	$dbh->do("delete from metadata where inode=$inode") or die $dbh->errstr;
	$dbh->do("delete from data     where inode=$inode") or die $dbh->errstr;
	$dbh->commit;
    };
    if ($@) {
	warn "commit aborted due to $@";
	eval {$dbh->rollback};
    }
}

sub remove_dir {
    my $self = shift;
    my $path = shift;
    my ($inode,$parent,$name) = $self->path2inode($path) ;
    $self->check_perm($parent,W_OK);
    $self->_isdir($inode)                or croak "$path is not a directory";
    $self->_getdir($inode )             and croak "$path is not empty";

    my $dbh   = $self->dbh;
    eval {
	$dbh->begin_work;
	$dbh->do("update metadata set links=links-1 where inode=$inode");
	$dbh->do("update metadata set links=links-1 where inode=$parent");
	$dbh->do("delete from path where inode=$inode");
	$self->unlink_inode($inode);
	$dbh->commit;
    };
    if($@) {
	eval {$dbh->rollback()};
	die "update aborted due to $@";
    }
}    

sub chown {
    my $self              = shift;
    my ($path,$uid,$gid)  = @_;
    my $inode             = $self->path2inode($path) ;

    # permission checking here
    my $ctx = fuse_get_context();
    die "permission denied" unless $uid == 0xffffffff || $ctx->{uid} == 0;

    my $groups            = $self->get_groups(@{$ctx}{'uid','gid'});
    die "permission denied" unless $gid == 0xffffffff || $ctx->{uid} == 0 || $groups->{$gid};

    my $dbh               = $self->dbh;
    eval {
	$dbh->begin_work();
	$dbh->do("update metadata set uid=$uid where inode=$inode") if $uid!=0xffffffff;
	$dbh->do("update metadata set gid=$gid where inode=$inode") if $gid!=0xffffffff;
	$dbh->commit();
    };
    if ($@) {
	eval {$dbh->rollback()};
	die "update aborted due to $@";
    }
}

sub chmod {
    my $self         = shift;
    my ($path,$mode) = @_;
    my $inode        = $self->path2inode($path) ;
    my $dbh          = $self->dbh;
    return $dbh->do("update metadata set mode=((0xf000&mode)|$mode) where inode=$inode");
}

sub fstat {
    my $self  = shift;
    my ($path,$inode) = @_;
    $inode ||= $self->path2inode;
    my $dbh          = $self->dbh;
    my ($ino,$mode,$uid,$gid,$nlinks,$ctime,$mtime,$atime,$size) =
	$dbh->selectrow_array(<<END);
select n.inode,mode,uid,gid,links,
       unix_timestamp(ctime),unix_timestamp(mtime),unix_timestamp(atime),
       length
 from metadata as n
 left join data as c on (n.inode=c.inode)
 where n.inode=$inode
END
;
    $ino or die $dbh->errstr;

    my $dev     = 0;
    my $blocks  = 1;
    my $blksize = BLOCKSIZE;
    return ($dev,$ino,$mode,$nlinks,$uid,$gid,0,$size,$atime,$mtime,$ctime,$blksize,$blocks);
}

sub stat {
    my $self         = shift;
    my $path         = shift;
    my $inode        = $self->path2inode($path);
    return $self->fstat($path,$inode);
}

sub read {
    my $self = shift;
    my ($path,$length,$offset,$inode) = @_;

    unless ($inode) {
	$inode  = $self->path2inode($path);
	$self->_isdir($inode) and croak "$path is a directory";
    }
    $self->flush(undef,$inode);  # make sure all in-memory data written to database
    $offset  ||= 0;

    my $first_block = int($offset / BLOCKSIZE);
    my $last_block  = int(($offset+$length) / BLOCKSIZE);
    my $start       = $offset % BLOCKSIZE;
    my $data = '';
    
    my $current_length = $self->file_length($inode);
    if ($length+$offset > $current_length) {
	$length = $current_length - $offset;
    }

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare_cached(<<END);
select block,contents 
   from data where inode=? 
   and block between ? and ? 
   order by block
END
;
    $sth->execute($inode,$first_block,$last_block);

    my $previous_block;
    while (my ($block,$contents) = $sth->fetchrow_array) {
	$previous_block = $block unless defined $previous_block;

	# a hole spanning an entire block
	if ($block - $previous_block > 1) {
	    $data .= "\0"x(BLOCKSIZE*($block-$previous_block-1));
	}
	$previous_block = $block;

	# a hole spanning a portion of a block
	if (length $contents < BLOCKSIZE && $block < $last_block) {
	    $contents .= "\0"x(BLOCKSIZE-length($contents));  # this is a hole!
	}
	$data      .= substr($contents,$start,$length);
	$length    -= BLOCKSIZE;
	$start      = 0;
    }
    $sth->finish;
    return $data;
}

sub file_length {
    my $self = shift;
    my $inode = shift;
    my $dbh   = $self->dbh;
    my ($current_length) = $dbh->selectrow_array("select length from metadata where inode=$inode");
    return $current_length;
}

sub open {
    my $self = shift;
    my ($path,$flags,$info,$uid,$gid) = @_;
    my $inode  = $self->path2inode($path);
    $self->check_open_perm($inode,$flags,$uid,$gid);
    # mtime=mtime to avoid updating the modification time!
    $self->dbh->do("update metadata set inuse=inuse+1,mtime=mtime where inode=$inode");
    return $inode;
}

sub access {
    my $self = shift;
    my ($path,$access_mode) = @_;
    my $inode = $Self->path2inode($path);
    return $self->check_perm($inode,$access_mode);
}

sub check_open_perm {
    my $self = shift;
    my ($inode,$flags) = @_;
    $flags         &= 0x3;
    my $wants_read  = $flags==O_RDONLY || $flags==O_RDWR;
    my $wants_write = $flags==O_WRONLY || $flags==O_RDWR;
    my $mask        = 0000;
    $mask          |= R_OK if $wants_read;
    $mask          |= W_OK if $wants_write;
    return $self->check_perm($inode,$mask);
}

# traverse path recursively, checking for X permission
sub check_path {
    my $self = shift;
    my ($dir,$inode,$uid,$gid) = @_;
    my $groups   = $self->get_groups($uid,$gid);

    my $dbh      = $self->dbh;
    my $sth = $dbh->prepare_cached(<<END);
select p.parent,m.mode,m.uid,m.gid
       from path as p,metadata as m
       where p.inode=m.inode
       and   p.inode=? and p.name=?
END
;
    my $name  = basename($dir);
    my $ok  = 1;
    while ($ok) {
	$sth->execute($inode,$name);
	my ($node,$mode,$owner,$group) = $sth->fetchrow_array() or last;
	my $mask     = $uid==$owner       ? S_IXUSR
	               :$groups->{$group} ? S_IXGRP
                       :S_IXOTH;
	my $allowed = $mask & $mode;
	$ok &&= $allowed;
	$inode          = $node;
	$dir            = $self->_dirname($dir);
	$name           = basename($dir);
    }
    $sth->finish;
    return $ok;
}

sub check_perm {
    my $self = shift;
    my ($inode,$access_mode) = @_;
    my $ctx = fuse_get_context();
    my ($uid,$gid) = @{$ctx}{'uid','gid'};

    my $dbh      = $self->dbh;

    my ($mode,$owner,$group) 
	= $dbh->selectrow_array("select 0xfff&mode,uid,gid from metadata where inode=$inode");

    my $groups      = $self->get_groups($uid,$gid);
    my $perm_word   = $uid==$owner      ? $mode >> 6
                     :$groups->{$group} ? $mode >> 3
                     :$mode;
    $perm_word     &= 07;

#    warn sprintf("check_perm(%d): access_mode=0%o, allowed=%d, mode=0%o, owner=%d, group=%d, uid=%d, gid=%d\n",
#		 $inode,$access_mode,$perm_word & $access_mode,$mode,$owner,$group,$uid,$gid);

    $access_mode==($perm_word & $access_mode) or die "permission denied";
    return 0;
}     

sub release {
    my ($self,$inode) = @_;
    $self->flush(undef,$inode);  # write cached blocks
    my $dbh = $self->dbh;
    # mtime=mtime to avoid updating the modification time!
    $dbh->do("update metadata set inuse=inuse-1,mtime=mtime where inode=$inode");
    $self->unlink_inode($inode);
    return 0;
}

sub write {
    my $self = shift;
    my ($path,$data,$offset,$inode) = @_;

    unless ($inode) {
	$inode  = $self->path2inode($path);
	$self->_isdir($inode) and croak "$path is a directory";
    }

    $offset  ||= 0;

    my $first_block    = int($offset / BLOCKSIZE);
    my $start          = $offset % BLOCKSIZE;

    my $block          = $first_block;
    my $bytes_to_write = length $data;
    my $bytes_written  = 0;
    unless ($Blockbuff{$inode}) {
	my %hash;
	share (%hash);
	$Blockbuff{$inode}=\%hash;
    }
    my $blocks         = $Blockbuff{$inode}; # blockno=>data
    lock $blocks;

    while ($bytes_to_write > 0) {
	my $bytes          = BLOCKSIZE > ($bytes_to_write+$start) ? $bytes_to_write : (BLOCKSIZE-$start);
	my $current_length = length($blocks->{$block}||'');

	if ($bytes < BLOCKSIZE && !$current_length) {  # partial block replacement, and not currently cached
	    my $sth = $self->dbh->prepare_cached('select contents,length(contents) from data where inode=? and block=?');
	    $sth->execute($inode,$block);
	    ($blocks->{$block},$current_length) = $sth->fetchrow_array();
	    $current_length                   ||= 0;
	    $sth->finish;
	}

	if ($start > $current_length) {  # hole in current block
	    my $padding  = "\0" x ($start-$current_length);
	    $padding   ||= '';
	    $blocks->{$block} .= $padding;
	}

	if ($start) {
	    substr($blocks->{$block},$start,$bytes,substr($data,$bytes_written,$bytes));
	} else {
	    $blocks->{$block} = substr($data,$bytes_written,$bytes);
	}

	$start = 0;  # no more offsets
	$block++;
	$bytes_written  += $bytes;
	$bytes_to_write -= $bytes;
    }
    $self->flush(undef,$inode) if keys %$blocks > FLUSHBLOCKS;
    return $bytes_written;
}

sub flush {
    my $self  = shift;
    my ($path,$inode) = @_;

    if ($path) {
	$inode  ||= $self->path2inode($path);
    }

    # if called with no inode, then recursively call ourselves
    # to flush all cached inodes
    unless ($inode) {
	for my $i (keys %{$self->{blockbuff}}) {
	    $self->flush(undef,$i);
	}
	return;
    }

    my $blocks = $Blockbuff{$inode} or return;

    lock $blocks;
    my $length = $self->file_length($inode);
    my $hwm = 0;  # high water mark ;-)

    my $dbh = $self->dbh;

    eval {
	$dbh->begin_work;
	my $sth = $dbh->prepare_cached(<<END) or die $dbh->errstr;
insert into data (inode,block,contents) values (?,?,?)
 on duplicate key update contents=?
END
;

	for my $block (keys %$blocks) {
	    my $data = $blocks->{$block};
	    $sth->execute($inode,$block,$data,$data);
	    my $a   = $block * BLOCKSIZE + length($data);
	    $hwm    = $a if $a > $hwm;
	}
	$sth->finish;
	$dbh->do("update metadata set length=$hwm where inode=$inode") if $hwm > $length;
	$dbh->commit();
    };

    if ($@) {
	warn "write failed with $@";
	eval{$dbh->rollback()};
	return;
    }

    %{$Blockbuff{$inode}} = ();
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

    my $last_block = int($length/BLOCKSIZE);
    my $trunc      = $length % BLOCKSIZE;
    eval {
	$dbh->begin_work;
	$dbh->do("delete from data where inode=$inode and block>$last_block");
	$dbh->do("update data set contents=substr(contents,1,$trunc) where inode=$inode and block=$last_block");
	$dbh->do("update metadata set length=$length where inode=$inode");
	$dbh->commit;
    };
    if ($@) {
	eval {$dbh->rollback()};
	die "Couldn't update because $@";
    }
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

sub utime {
    my $self = shift;
    my ($path,$atime,$mtime,$uid,$gid) = @_;
    my $inode = $self->path2inode($path) ;
    $self->check_perm($inode,W_OK,$uid,$gid);
    my $dbh    = $self->dbh;
    my $sth    = $dbh->prepare_cached("update metadata set atime=from_unixtime(?),mtime=from_unixtime(?)");
    my $result = $sth->execute($atime,$mtime);
    $sth->finish();
    return $result;
}

sub getdir {
    my $self = shift;
    my ($path,$uid,$gid) = @_;
    my $inode = $self->path2inode($path);
    $self->_isdir($inode) or croak "not directory";
    $self->check_perm($inode,X_OK|R_OK);
    return $self->_getdir($inode);
}

sub _getdir {
    my $self  = shift;
    my $inode = shift;
    my $dbh   = $self->dbh;
    my $col   = $dbh->selectcol_arrayref("select name from path where parent=$inode");
    return '.','..',@$col;
}

sub errno {
    my $self = shift;
    my $message = shift;
    return -ENOENT()    if $@ =~ /not found/;
    return -EISDIR()    if $@ =~ /is a directory/;
    return -ENOTDIR()   if $@ =~ /not a directory/;
    return -EINVAL()    if $@ =~ /length beyond end of file/;
    return -ENOTEMPTY() if $@ =~ /not empty/;
    return -EACCES()    if $@ =~ /permission denied/;
    return -EIO()       if $@;
}

# in scalar context return inode
# in list context return (inode,parent_inode,name)
sub path2inode {
    my $self   = shift;
    my $path   = shift;
    my ($inode,$p_inode,$name) = $self->_path2inode($path);

    my $ctx = fuse_get_context();
    $self->check_path($self->_dirname($path),$p_inode,@{$ctx}{'uid','gid'}) or die "permission denied";
    return wantarray ? ($inode,$p_inode,$name) : $inode;
}

sub _path2inode {
    my $self   = shift;
    my $path   = shift;
    if ($path eq '/') {
	return wantarray ? (1,undef,'/') : 1;
    }
    $path =~ s!/$!!;
    my ($sql,@bind) = $self->_path2inode_sql($path);
    my $dbh    = $self->dbh;
    my $sth    = $dbh->prepare_cached($sql) or croak $dbh->errstr;
    $sth->execute(@bind);
    my @v      = $sth->fetchrow_array() or croak "$path not found";
    $sth->finish;
    return @v;
}

sub _dirname {
    my $self = shift;
    my $path = shift;
    my $dir  = dirname($path);
    $dir     = '/' if $dir eq '.'; # work around funniness in dirname()    
    return $dir;
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
;
}

sub _initialize_schema {
    my $self = shift;
    my $dbh  = $self->dbh;
    $dbh->do('drop table if exists metadata') or croak $dbh->errstr;
    $dbh->do('drop table if exists path')     or croak $dbh->errstr;
    $dbh->do('drop table if exists data')     or croak $dbh->errstr;
    $dbh->do($self->_metadata_table_def)      or croak $dbh->errstr;
    $dbh->do($self->_path_table_def)          or croak $dbh->errstr;
    $dbh->do($self->_data_table_def)          or croak $dbh->errstr;

    # create the root node
    # should update this to use fuse_get_context to get proper uid, gid and masked permissions
    my $mode = (0040000|0777)&~umask();
    my $uid = $<;
    my $gid = $(;
    $gid    =~ s/ .+$//;
    $dbh->do("insert into metadata (inode,mode,uid,gid,links,mtime,ctime,atime) values(1,$mode,$uid,$gid,2,null,null,null)") 
	or croak $dbh->errstr;
    $dbh->do("insert into path (inode,name,parent) values (1,'/',null)")
	or croak $dbh->errstr;
}

sub get_groups {
    my $self = shift;
    my ($uid,$gid) = @_;
    return $self->{_group_cache}{$uid} ||= $self->_get_groups($uid,$gid);
}

sub _get_groups {
    my $self = shift;
    my ($uid,$gid) = @_;
    my %result;
    $result{$gid}++;
    my $username = getpwuid($uid) or return \%result;
    while (my($name,undef,$id,$members) = getgrent) {
	next unless $members =~ /\b$username\b/;
	$result{$id}++;
    }
    endgrent;
    return \%result;
}

1;

__END__
