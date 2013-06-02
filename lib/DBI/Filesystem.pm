package DBI::Filesystem;

=head1 NAME

DBI::Filesystem - Store a filesystem in a relational database

=head1 SYNOPSIS

 use DBI::Filesystem;

 # Preliminaries. Create the mount point:
 mkdir '/tmp/mount';

 # Create the databas:
 system "mysqladmin -uroot create test_filesystem"; 
 system "mysql -uroot -e 'grant all privileges on test_filesystem.* to $ENV{USER}@localhost' mysql";

 # (Usually you would do this in the shell.)
 # (You will probably need to add the admin user's password)

 # Create the filesystem object
 $fs = DBI::Filesystem->new('dbi:mysql:test_filesystem',{initialize=>1});

 # Mount it on the mount point.
 # This call will block until the filesystem is mounted by another
 # process by calling "fusermount -u /tmp/mount"
 $fs->mount('/tmp/mount');

 # Alternatively, manipulate the filesystem directly from within Perl.
 # Any of these methods could raise a fatal error, so always wrap in
 # an eval to catch those errors.
 eval {
   # directory creation
   $fs->create_directory('/dir1');
   $fs->create_directory('/dir1/subdir_1a');

   # file creation
   $fs->create_file('/dir1/subdir_1a/test.txt');

   # file I/O
   $fs->write('/dir1/subdir_1a/test.txt','This is my favorite file',0);
   my $data = $fs->read('/dir1/subdir_1a/test.txt',100,0);

   # reading contents of a directory
   my @entries = $fs->getdir('/dir1');

   # fstat file/directory
   my @stat = $fs->stat('/dir1/subdir_1a/test.txt');

   #chmod/chown file
   $fs->chmod('/dir1/subdir_1a/test.txt',0600);
   $fs->chown('/dir1/subdir_1a/test.txt',1001,1001); #uid,gid

   # rename file/directory
   $fs->rename('/dir1'=>'/dir2');

   # create a symbolic link
   $fs->create_symlink('/dir2' => '/dir1');

   # create a hard link
   $fs->create_hardlink('/dir2/subdir_1a/test.txt' => '/dir2/hardlink.txt');

   # read symbolic link
   my $target = $fs->read_symlink('/dir1/symlink.txt');

   # unlink a file
   $fs->unlink_file('/dir2/subdir_1a/test.txt');

   # remove a directory
   $fs->remove_directory('/dir2/subdir_1a');

   # get the inode (integer) that corresponds to a file/directory
   my $inode = $fs->path2inode('/dir2');

   # get the path(s) that correspond to an inode
   my @paths = $fs->inode2paths($inode);
 };
 if ($@) { warn "file operation failed with $@"; }
 
=head1 DESCRIPTION

This module can be used to create a fully-functioning "Fuse" userspace
filesystem on top of a relational database. Unlike other
filesystem-to-DBM mappings, such as Fuse::DBI, this one creates and
manages a specific schema designed to support filesystem
operations. If you wish to mount a filesystem on an arbitrary DBM
schema, you probably want Fuse::DBI, not this.

Most filesystem functionality is implemented, including hard and soft
links, sparse files, ownership and access modes, UNIX permission
checking and random access to binary files. Very large files (up to
multiple gigabytes) are supported without performance degradation.

Why would you use this? The main reason is that it allows you to use
DBMs functionality such as accessibility over the network, database
replication, failover, etc. In addition, the underlying
DBI::Filesystem module can be extended via subclassing to allow
additional functionality such as arbitrary access control rules,
searchable file and directory metadata, full-text indexing of file
contents, etc.

Before mounting the DBMS, you must have created the database and
assigned yourself sufficient privileges to read and write to it. You
must also create an empty directory to serve as the mount point.

A convenient front-end to this library is provided by B<sqlfs.pl>,
which is installed along with this library.

=head2 Unsupported Features

The following features are not implemented:

 * statfs -- df on the filesystem will not provide any useful information
            on free space or other filesystem information.

 * extended attributes -- Extended attributes are not supported.

 * nanosecond times -- atime, mtime and ctime are accurate only to the
            second.

 * ioctl -- none are supported

 * poll  -- polling on the filesystem to detect file update events will not work.

 * lock  -- file handle locking among processes running on the local machine 
            works, but protocol-level locking, which would allow cooperative 
            locks on different machines talking to the same database server, 
            is not implemented.

You must be the superuser in order to create a file system with the
suid and dev features enabled, and must invoke this commmand with
the mount options "allow_other", "suid" and/or "dev":

   -o dev,suid,allow_other

=head2 Supported Database Management Systems

DBMSs differ in what subsets of the SQL language they support,
supported datatypes, date/time handling, and support for large binary
objects. DBI::Filesystem currently supports MySQL, PostgreSQL and
SQLite. Other DBMSs can be supported by creating a subclass file
named, e.g. DBI::Filesystem:Oracle, where the last part of the class
name corresponds to the DBD driver name ("Oracle" in this
example). See DBI::Filesystem::SQLite, DBI::Filesystem::mysql and
DBI::Filesystem:Pg for an illustration of the methods that need to be
defined/overridden.

=head2 Fuse Installation Notes

For best performance, you will need to run this filesystem using a
version of Perl that supports IThreads. Otherwise it will fall back to
non-threaded mode, which will introduce occasional delays during
directory listings and have notably slower performance when reading
from more than one file simultaneously.

If you are running Perl 5.14 or higher, you *MUST* use at least 0.15
of the Perl Fuse module. At the time this was written, the version of
Fuse 0.15 on CPAN was failing its regression tests on many
platforms. I have found that the easiest way to get a fully
operational Fuse module is to clone and compile a patched version of
the source, following this recipe:

 $ git clone git://github.com/dpavlin/perl-fuse.git
 $ cd perl-fuse
 $ perl Makefile.PL
 $ make test   (optional)
 $ sudo make install

=head1 METHODS

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

our $VERSION = '1.00';

use constant MAX_PATH_LEN => 4096;  # characters
use constant BLOCKSIZE    => 16384;  # bytes
use constant FLUSHBLOCKS  => 256;    # flush after we've accumulated this many cached blocks

my %Blockbuff :shared;


=head2 $fs = DBI::Filesystem->new($dsn,{options...})

Create the new DBI::Filesystem object. The mandatory first argument is
a DBI data source, in the format "dbi:<driver>:<other_arguments>". The
other arguments may include the database name, host, port, and
security credentials. See the documentation for your DBMS for details.

Non-mandatory options are contained in a hash reference with one or
more of the following keys:

 initialize          If true, then initialize the database schema. Many
                     DBMSs require you to create the database first.

 ignore_permissions  If true, then Unix permission checking is not
                     performed when creating/reading/writing files.

WARNING: Initializing the schema quietly destroys anything that might
have been there before!

=cut

# DBI::Filesystem->new($dsn,{create=>1,ignore_permissions=>1})
sub new {
    my $class = shift;
    my ($dsn,$options) = @_;

    my ($dbd)          = $dsn =~ /dbi:([^:]+)/;
    $dbd or croak "Could not figure out the DBI subclass to load from $dsn";

    # load the appropriate DBD subclass and fix up its @ISA so that we become
    # the parent class
    my $c        = ref $class||$class;
    my $subclass = __PACKAGE__.'::'.$dbd;
    eval "require $subclass;1" or croak $@  unless $subclass->can('new');
    eval "unshift \@$subclass\:\:ISA,'$c'   unless \$subclass->isa('$c')";
    die $@ if $@;

    my $self  = bless {
	dsn          => $dsn,
	%$options
    },$subclass;

    $self->initialize_schema if $options->{initialize};
    return $self;
}

=head2 $boolean = $fs->ignore_permissions([$boolean]);

Get/set the ignore_permissions flag. If ignore_permissions is true,
then all permission checks on file and directory access modes are
disabled, allowing you to create files owned by root, etc.

=cut

sub ignore_permissions {
    my $self = shift;
    my $d    = $self->{ignore_permissions};
    $self->{ignore_permissions} = shift if @_;
    $d;
}

############### filesystem handlers below #####################

our $Self;   # because entrypoints cannot be passed as closures

=head2 $fs->mount($mountpoint, [\%fuseopts])

This method will mount the filesystem on the indicated mountpoint
using Fuse and block until the filesystem is unmounted using the
"fusermount -u" command or equivalent. The mountpoint must be an empty
directory unless the "nonempty" mount option is passed.

You may pass in a hashref of options to pass to the Fuse
module. Recognized options and their defaults are:

 debug        Turn on verbose debugging of Fuse operations [false]
 threaded     Turn on threaded operations [true]
 nullpath_ok  Allow filehandles on open files to be used even after file
               is unlinked [true]
 mountopts    Comma-separated list of mount options

Mount options to be passed to Fuse are described at
http://manpages.ubuntu.com/manpages/precise/man8/mount.fuse.8.html. In
addition, you may pass the usual mount options such as "ro", etc. They
are presented as a comma-separated list as shown here:

 $fs->mount('/tmp/foo',{debug=>1,mountopts=>'ro,nonempty'})

Common mount options include:

Fuse specific
 nonempty      Allow mounting over non-empty directories if true [false]
 allow_other   Allow other users to access the mounted filesystem [false]
 fsname        Set the filesystem source name shown in df and /etc/mtab
 auto_cache    Enable automatic flushing of data cache on open [false]
 hard_remove   Allow true unlinking of open files [true]
 nohard_remove Activate alternate semantics for unlinking open files
                (see below)

General
 ro          Read-only filesystem
 dev         Allow device-special files
 nodev       Do not allow device-special files
 suid        Allow suid files
 nosuid      Do not allow suid files
 exec        Allow executable files
 noexec      Do not allow executable files
 atime       Update file/directory access times
 noatime     Do not update file/directory access times

Some options require special privileges. In particular allow_other
must be enabled in /etc/fuse.conf, and the dev and suid options can
only be used by the root user.

The "hard_remove" mount option is passed by default. This option
allows files to be unlinked in one process while another process holds
an open filehandle on them. The contents of the file will not actually
be deleted until the last open filehandle is closed. The downside of
this is that certain functions will fail when called on filehandles
connected to unlinked files, including fstat(), ftruncate(), chmod(),
and chown(). If this is an issue, then pass option
"nohard_remove". This will activate Fuse's alternative semantic in
which unlinked open files are renamed to a hidden file with a name
like ".fuse_hiddenXXXXXXX'. The hidden file is removed when the last
filehandle is closed.

=cut

sub mount {
    my $self = shift;
    my $mtpt = shift or croak "Usage: mount(\$mountpoint)";
    my $fuse_opts = shift;

    $fuse_opts ||= {};

    my %mt_opts = map {$_=>1} split ',',$fuse_opts->{mountopts};
    $mt_opts{hard_remove}++ unless $mt_opts{nohard_remove};
    delete $mt_opts{nohard_remove};
    $fuse_opts->{mountopts} = join ',',keys %mt_opts;

    my $pkg  = __PACKAGE__;

    $Self = $self;  # because entrypoints cannot be passed as closures
    $self->check_schema 
	or croak "This database does not appear to contain a valid schema. Do you need to initialize it?\n";
    $self->mounted(1);
    my @args = (
	mountpoint  => $mtpt,
	getdir      => "$pkg\:\:e_getdir",
	getattr     => "$pkg\:\:e_getattr",
	fgetattr    => "$pkg\:\:e_fgetattr",
	open        => "$pkg\:\:e_open",
	release     => "$pkg\:\:e_release",
	flush       => "$pkg\:\:e_flush",
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
	%$fuse_opts,
	);
    push @args,$self->_subclass_implemented_calls();
    Fuse::main(@args);
}

# this method detects when one of the currently unimplemented
# Fuse methods is defined in a subclass, and creates the appropriate
# Fuse stub to call it
sub _subclass_implemented_calls{
    my $self = shift;
    my @args;

    my @u = (qw(statfs fsync 
                setxattr getxattr listxattr removexattr
                opendir readdir releasedir fsyncdir
                init destroy ftruncate lock utimens
                bmap ioctl poll));
    my @implemented = grep {$self->can($_)} @u;

    my $pkg  = __PACKAGE__;
    foreach my $method (@implemented) {
	my $hook = "$pkg\:\:e_$method";
	eval <<END;
sub $hook {
    my \$path   = fixup(shift) if \@_;
    my \@result = eval {\$${pkg}\:\:Self->$method(\$path,\@_)};
    return \$Self->errno(\$@) if \$@;
    return wantarray ? \@result:\$result[0];
}
END
    ;
	warn $@ if $@;
	push @args,($method => $hook);
    }
    return @args;
}

=head2 $boolean = $fs->mounted([$boolean])

This method returns true if the filesystem is currently
mounted. Subclasses can change this value by passing the new value as
the argument.

=back

sub mounted {
    my $self = shift;
    my $d = $self->{mounted};
    $self->{mounted} = shift if @_;
    return $d;
}

=head2 $fixed_path = fixup($path)

This is an ordinary function (not a method) that removes the initial
slash from paths passed to this module from Fuse. The root directory is unchanged:

 Before      After fixup()
 ------      -------------
 /foo        foo
 /foo/bar    foo/bar
 /          /

To call this method from subclasses, invoke it as DBI::Filesystem::fixup().

=back

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

    $mode   |= 0040000;
    my $ctx            = $Self->get_context();
    my $umask          = $ctx->{umask};
    eval {$Self->create_directory($path,$mode&(~$umask))};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_mknod {
    my $path = fixup(shift);
    my ($mode,$device) = @_;
    my $ctx            = $Self->get_context;
    my $umask          = $ctx->{umask};
    eval {$Self->create_file($path,$mode&(~$umask),$device)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_create {
    my $path = fixup(shift);
    my ($mode,$flags) = @_;
    # warn sprintf("create(%s,0%o,0%o)",$path,$mode,$flags);
    my $ctx            = $Self->get_context;
    my $umask          = $ctx->{umask};
    my $fh = eval {
	$Self->create_file($path,$mode&(~$umask));
	$Self->open($path,$flags,{});
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
    eval {$Self->release($fh)};
    return $Self->errno($@) if $@;
    return 0;
}

sub e_flush {
    my ($path,$fh) = @_;
    eval {$Self->flush($path,$fh)};
    return $Self->errno($@) if $@;
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
    return $self->{dbh} ||= eval {DBI->connect($dsn,
					       undef,undef,
					       {RaiseError=>1,
						AutoCommit=>1})} || do {warn $@; croak $@;};
}

sub create_inode {
    my $self        = shift;
    my ($type,$mode,$rdev,$uid,$gid) = @_;

    unless (defined $mode) {
	$mode  = 0777 ;
	$mode |=  $type eq 'f' ? 0100000
	         :$type eq 'd' ? 0040000
	         :$type eq 'l' ? 0120000
	         :0100000;  # default
    }

    $uid  ||= 0;
    $gid  ||= 0;
    $rdev ||= 0;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare_cached($self->_create_inode_sql);
    $sth->execute($mode,$uid,$gid,$rdev,$type eq 'd' ? 1 : 0) or die $sth->errstr;
    $sth->finish;
    return $self->last_inserted_inode($dbh);
}

sub last_inserted_inode {
    my $self = shift;
    my $dbh  = shift;
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
    my $newnode= $self->create_inode_and_path($newpath,'l',0120777);
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
    $self->touch($parent,'ctime');
    $self->touch($parent,'mtime');
}

sub create_inode_and_path {
    my $self = shift;
    my ($path,$type,$mode,$rdev) = @_;
    my $dbh    = $self->dbh;
    my $inode;

    my $parent = $self->path2inode($self->_dirname($path));
    $self->check_perm($parent,W_OK);

    my $ctx = $self->get_context;

    eval {
	$dbh->begin_work;
	$inode  = $self->create_inode($type,$mode,$rdev,@{$ctx}{'uid','gid'});
	$self->create_path($inode,$path);
	$dbh->commit;
    };
    if ($@) {
	eval{$dbh->rollback()};
	die "commit failed due to $@";
    }
    return $inode;
}

sub create_file { 
    my $self = shift;
    my ($path,$mode,$rdev) = @_;
    $self->create_inode_and_path($path,'f',$mode,$rdev);
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

    eval {
	$dbh->begin_work();
	$dbh->do("update metadata set links=links-1 where inode=$inode");
	$dbh->do("update metadata set links=links-1 where inode=$parent");
	$self->touch($parent,'mtime');
	$self->touch($parent,'ctime');
	$dbh->commit();
    };
    if ($@) {
	eval {$dbh->rollback()};
	die "unlink failed due to $@";
    }
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
	$dbh->do("delete from extents  where inode=$inode") or die $dbh->errstr;
	$dbh->commit;
    };
    if ($@) {
	eval {$dbh->rollback};
	die "commit aborted due to $@";
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
	my $now = $self->_now_sql;
	$dbh->do("update metadata set links=links-1,ctime=$now where inode=$inode");
	$dbh->do("update metadata set links=links-1,ctime=$now where inode=$parent");
	$dbh->do("delete from path where inode=$inode");
	$self->touch($parent,'ctime');
	$self->touch($parent,'mtime');
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
    my $ctx = $self->get_context;
    die "permission denied" unless $uid == 0xffffffff || $ctx->{uid} == 0;

    my $groups            = $self->get_groups(@{$ctx}{'uid','gid'});
    die "permission denied" unless $gid == 0xffffffff || $ctx->{uid} == 0 || $groups->{$gid};

    my $dbh               = $self->dbh;
    eval {
	$dbh->begin_work();
	$dbh->do("update metadata set uid=$uid where inode=$inode") if $uid!=0xffffffff;
	$dbh->do("update metadata set gid=$gid where inode=$inode") if $gid!=0xffffffff;
	$self->touch($inode,'ctime');
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
    my $f000         = 0xf000;
    my $now          = $self->_now_sql;
    return $dbh->do("update metadata set mode=(($f000&mode)|$mode),ctime=$now where inode=$inode");
}

sub fstat {
    my $self  = shift;
    my ($path,$inode) = @_;
    $inode ||= $self->path2inode;
    my $dbh          = $self->dbh;
    my ($ino,$mode,$uid,$gid,$rdev,$nlinks,$ctime,$mtime,$atime,$size) =
	$dbh->selectrow_array($self->_fstat_sql($inode));
    $ino or die $dbh->errstr;

    # make sure write buffer contributes
    if (my $blocks = $Blockbuff{$inode}) {
	lock $blocks; 
	if (keys %$blocks) { 
	    my ($biggest) = sort {$b<=>$a} keys %$blocks; 
	    my $offset    = $self->blocksize * $biggest + length $blocks->{$biggest}; 
	    $size         = $offset if $offset > $size;
	}
    }

    my $dev     = 0;
    my $blocks  = 1;
    my $blksize = $self->blocksize;
    return ($dev,$ino,$mode,$nlinks,$uid,$gid,$rdev,$size,$atime,$mtime,$ctime,$blksize,$blocks);
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
    $offset  ||= 0;

    my $blksize     = $self->blocksize;
    my $first_block = int($offset / $blksize);
    my $last_block  = int(($offset+$length) / $blksize);
    my $start       = $offset % $blksize;
    
    $self->flush(undef,$inode);
    my $get_atime = $self->_get_unix_timestamp_sql('atime');
    my $get_mtime = $self->_get_unix_timestamp_sql('mtime');
    my ($current_length,$atime,$mtime) = 
	$self->dbh->selectrow_array("select length,$get_atime,$get_mtime from metadata where inode=$inode");
    if ($length+$offset > $current_length) {
	$length = $current_length - $offset;
    }
    my $data = $self->_read_direct($inode,$start,$length,$first_block,$last_block);
    $self->touch($inode,'atime') if length $data && $atime < $mtime;
    return $data;
}

# This type of read checks the write buffer for cached data.
# If cached doesn't exist, then performs one SQL query for each block.
# COMMENTED BECAUSE IT ACTUALLY SLOWS PERFORMANCE!
# sub _read_cached {
#     my $self = shift;
#     my ($blocks,$inode,$start,$length,$first_block,$last_block) = @_;

#     my $dbh = $self->dbh;
#     my $sth = $dbh->prepare_cached(<<END);
# select contents 
#    from data where inode=? 
#    and block=?
# END
# ;
#     my $previous_block;
#     my $data = '';
#     for (my $block=$first_block;$block<=$last_block;$block++) {
# 	my $contents;
# 	if ($blocks->{$block}) {
# 	    $contents = $blocks->{$block};
# 	} else {
# 	    $sth->execute($inode,$block);
# 	    ($contents) = $sth->fetchrow_array;
# 	}
# 	next unless length $contents;

# 	$previous_block = $block unless defined $previous_block;
# 	# a hole spanning an entire block
# 	if ($block - $previous_block > 1) {
# 	    $data .= "\0"x(BLOCKSIZE*($block-$previous_block-1));
# 	}
# 	$previous_block = $block;
	
# 	# a hole spanning a portion of a block
# 	if (length $contents < BLOCKSIZE && $block < $last_block) {
# 	    $contents .= "\0"x(BLOCKSIZE-length($contents));  # this is a hole!
# 	}
# 	$data      .= substr($contents,$start,$length);
# 	$length    -= BLOCKSIZE;
# 	$start      = 0;
#     }
#     $sth->finish;
#     return $data;
# }

# This type of read is invoked when there is no write buffer for
# the file. It executes a single SQL query across the data table.
sub _read_direct {
    my $self = shift;
    my ($inode,$start,$length,$first_block,$last_block) = @_;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare_cached(<<END);
select block,contents 
   from extents where inode=? 
   and block between ? and ?
   order by block
END
;
    $sth->execute($inode,$first_block,$last_block);

    my $blksize     = $self->blocksize;
    my $previous_block;
    my $data = '';
    while (my ($block,$contents) = $sth->fetchrow_array) {
	$previous_block = $block unless defined $previous_block;
	# a hole spanning an entire block
	if ($block - $previous_block > 1) {
	    $data .= "\0"x($blksize*($block-$previous_block-1));
	}
	$previous_block = $block;
	
	# a hole spanning a portion of a block
	if (length $contents < $blksize && $block < $last_block) {
	    $contents .= "\0"x($blksize-length($contents));  # this is a hole!
	}
	$data      .= substr($contents,$start,$length);
	$length    -= $blksize;
	$start      = 0;
    }
    $sth->finish();
    return $data;
}

sub file_length {
    my $self = shift;
    my $inode = shift;
    my @stat  = $self->fstat(undef,$inode);
    return $stat[7];
}

sub open {
    my $self = shift;
    my ($path,$flags,$info) = @_;
    my $inode  = $self->path2inode($path);
    $self->check_open_perm($inode,$flags);
    # mtime=mtime to avoid updating the modification time!
    $self->dbh->do("update metadata set inuse=inuse+1 where inode=$inode");
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

    return 1 if $self->ignore_permissions;

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

    return 1 if $self->ignore_permissions;

    my $ctx = $self->get_context;
    my ($uid,$gid) = @{$ctx}{'uid','gid'};

    return 0 if $uid==0; # root can do anything

    my $dbh      = $self->dbh;

    my $fff = 0xfff;
    my ($mode,$owner,$group) 
	= $dbh->selectrow_array("select $fff&mode,uid,gid from metadata where inode=$inode");

    my $groups      = $self->get_groups($uid,$gid);
    my $perm_word   = $uid==$owner      ? $mode >> 6
                     :$groups->{$group} ? $mode >> 3
                     :$mode;
    $perm_word     &= 07;

    $access_mode==($perm_word & $access_mode) or die "permission denied";
    return 0;
}     

sub release {
    my ($self,$inode) = @_;
    $self->flush(undef,$inode);  # write cached blocks
    my $dbh = $self->dbh;
    # mtime=mtime to avoid updating the modification time!
    $dbh->do("update metadata set inuse=inuse-1 where inode=$inode");
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

    my $blksize        = $self->blocksize;
    my $first_block    = int($offset / $blksize);
    my $start          = $offset % $blksize;

    my $block          = $first_block;
    my $bytes_to_write = length $data;
    my $bytes_written  = 0;
    unless ($Blockbuff{$inode}) {
	my %hash;
	$Blockbuff{$inode}=share(%hash);
    }
    my $blocks         = $Blockbuff{$inode}; # blockno=>data
    lock $blocks;

    my $dbh            = $self->dbh;
    while ($bytes_to_write > 0) {
	my $bytes          = $blksize > ($bytes_to_write+$start) ? $bytes_to_write : ($blksize-$start);
	my $current_length = length($blocks->{$block}||'');

	if ($bytes < $blksize && !$current_length) {  # partial block replacement, and not currently cached
	    my $sth = $dbh->prepare_cached('select contents,length(contents) from extents where inode=? and block=?');
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

	if ($blocks->{$block}) {
	    substr($blocks->{$block},$start,$bytes,substr($data,$bytes_written,$bytes));
	} else {
	    $blocks->{$block} = substr($data,$bytes_written,$bytes);
	}

	$start = 0;  # no more offsets
	$block++;
	$bytes_written  += $bytes;
	$bytes_to_write -= $bytes;
    }
    $self->flush(undef,$inode) if keys %$blocks > $self->flushblocks;
    return $bytes_written;
}

sub flush {
    my $self  = shift;
    my ($path,$inode) = @_;

    $inode  ||= $self->path2inode($path) if $path;

    # if called with no inode, then recursively call ourselves
    # to flush all cached inodes
    unless ($inode) {
	for my $i (keys %{$self->{blockbuff}}) {
	    $self->flush(undef,$i);
	}
	return;
    }

    my $blocks  = $Blockbuff{$inode} or return;
    my $blksize = $self->blocksize;

    lock $blocks;
    my $result = $self->_write_blocks($inode,$blocks,$blksize) or die "flush failed";

    delete $Blockbuff{$inode};
}

sub _write_blocks {
    my $self = shift;
    my ($inode,$blocks,$blksize) = @_;

    my $dbh = $self->dbh;
    my ($length) = $dbh->selectrow_array("select length from metadata where inode=$inode");
    my $hwm      = $length;  # high water mark ;-)

    eval {
	$dbh->begin_work;
	my $sth = $dbh->prepare_cached(<<END) or die $dbh->errstr;
replace into extents (inode,block,contents) values (?,?,?)
END
;
	for my $block (keys %$blocks) {
	    my $data = $blocks->{$block};
	    $sth->execute($inode,$block,$data);
	    my $a   = $block * $blksize + length($data);
	    $hwm    = $a if $a > $hwm;
	}
	$sth->finish;
	my $now = $self->_now_sql;
	$dbh->do("update metadata set length=$hwm,mtime=$now where inode=$inode");
	$dbh->commit();
    };

    if ($@) {
	my $msg = $@;
	eval{$dbh->rollback()};
	warn $msg;
	die "write failed with $msg";
	return;
    }

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

    my $last_block = int($length/$self->blocksize);
    my $trunc      = $length % $self->blocksize;
    eval {
	$dbh->begin_work;
	$dbh->do("delete from extents where inode=$inode and block>$last_block");
	$dbh->do("update      extents set contents=substr(contents,1,$trunc) where inode=$inode and block=$last_block");
	$dbh->do("update metadata set length=$length where inode=$inode");
	$self->touch($inode,'mtime');
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
    my $mask  = 0xf000;
    my $isdir = 0x4000;
    my ($result) = $dbh->selectrow_array("select ($mask&mode)=$isdir from metadata where inode=$inode")
	or die $dbh->errstr;
    return $result;
}

sub utime {
    my $self = shift;
    my ($path,$atime,$mtime) = @_;
    my $inode = $self->path2inode($path) ;
    $self->check_perm($inode,W_OK);
    my $dbh    = $self->dbh;
    my $sth    = $dbh->prepare_cached($self->_update_utime_sql);
    my $result = $sth->execute($atime,$mtime,$inode);
    $sth->finish();
    return $result;
}

sub touch {
    my $self  = shift;
    my ($inode,$field) = @_;
    my $now = $self->_now_sql;
    $self->dbh->do("update metadata set $field=$now where inode=$inode");
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
    warn $message if $message =~ /^(dbd|dbi)/i;
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

    my $ctx = $self->get_context;
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

# returns a list of paths that correspond to an inode
# because files can be hardlinked, there may be multiple paths!
sub inode2paths {
    my $self   = shift;
    my $inode  = shift;
    my $dbh    = $self->dbh;
    #BUG: inode is not indexed in this table, so this may be slow!
    # consider adding an index
    my $sth    = $dbh->prepare_cached('select name,parent from path where inode=?');
    $sth->execute($inode);
    my @results;
    while (my ($name,$parent) = $sth->fetchrow_array) {
	my $directory = $self->_inode2path($parent);
	push @results,"$directory/$name";
    }
    $sth->finish;
    return @results;
}

# recursive walk up the file tree
# this should only be called on directories, as we know
# they do not have hard links
sub _inode2path {
    my $self  = shift;
    my $inode = shift;
    return '' if $inode == 1;
    my $dbh  = $self->dbh;
    my ($name,$parent) = $dbh->selectrow_array("select name,parent from path where inode=$inode");
    return $self->_inode2path($parent)."/".$name;
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

sub initialize_schema {
    my $self = shift;
    local $self->{dbh};  # to avoid cloning database handle into child threads
    my $dbh  = $self->dbh;
    $dbh->do('drop table if exists metadata') or croak $dbh->errstr;
    $dbh->do('drop table if exists path')     or croak $dbh->errstr;
    $dbh->do('drop table if exists extents')  or croak $dbh->errstr;
    
    $dbh->do($_) foreach split ';',$self->_metadata_table_def;
    $dbh->do($_) foreach split ';',$self->_path_table_def;
    $dbh->do($_) foreach split ';',$self->_extents_table_def;

    # create the root node
    # should update this to use fuse_get_context to get proper uid, gid and masked permissions
    my $ctx  = $self->get_context;
    my $mode = (0040000|0777)&~$ctx->{umask};
    my $uid = $ctx->{uid};
    my $gid = $ctx->{gid};
    my $timestamp = $self->_now_sql();
    # potential bug here -- we assume the inode column begins at "1" automatically
    $dbh->do("insert into metadata (mode,uid,gid,links,mtime,ctime,atime) values($mode,$uid,$gid,2,$timestamp,$timestamp,$timestamp)") 
	or croak $dbh->errstr;
    $dbh->do("insert into path (inode,name,parent) values (1,'/',null)")
	or croak $dbh->errstr;
}

sub check_schema {
    my $self     = shift;
    local $self->{dbh};  # to avoid cloning database handle into child threads
    my ($result) = eval {
	$self->dbh->selectrow_array(<<END);
select 1 from metadata as m,path as p left join extents as e on e.inode=p.inode where m.inode=1 and p.parent=1
END
    };
    return !$@;
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

sub get_context {
    my $self = shift;
    return fuse_get_context() if $self->mounted;
    my ($gid) = $( =~ /^(\d+)/;
    return {
	uid   => $<,
	gid   => $gid,
	pid   => $$,
	umask => umask()
    }
}

################# a few SQL fragments; most are inline or in the DBD-specific descendents ######
sub _fstat_sql {
    my $self  = shift;
    my $inode = shift;
    my $times = join ',',map{$self->_get_unix_timestamp_sql($_)} 'ctime','mtime','atime';
    return <<END;
select inode,mode,uid,gid,rdev,links,
       $times,length
 from metadata
 where inode=$inode
END
}

sub _create_inode_sql {
    my $self = shift;
    my $now = $self->_now_sql;
    return "insert into metadata (mode,uid,gid,rdev,links,mtime,ctime,atime) values(?,?,?,?,?,$now,$now,$now)";
}

sub blocksize   { return 4096 }
sub flushblocks { return   64 }

1;


=head1 AUTHOR

Copyright 2013, Lincoln D. Stein <lincoln.stein@gmail.com>

=head1 LICENSE

This package is distributed under the terms of the Perl Artistic
License 2.0. See http://www.perlfoundation.org/artistic_license_2_0.

=cut

__END__
