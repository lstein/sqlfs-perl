#!/usr/bin/perl
 
=head1 NAME

sqlfs.pl - Mount Fuse filesystem on a SQL database

=head1 SYNOPSIS

 % sqlfs.pl [options] dbi:<driver_name>:database=<name>;<other_args> <mount point>

Options:

  --create                      initialize an empty filesystem
  --unmount                     unmount the indicated directory
  --foreground                  remain in foreground (false)
  --nothreads                   disable threads (false)
  --debug                       enable Fuse debugging messages
  --module=DBI::Filesystem::... Use a subclass of DBI::Filesystem

  --option=allow_other          allow other accounts to access filesystem (false)
  --option=default_permissions  enable permission checking by kernel (false)
  --option=fsname=name          set filesystem name (none)
  --option=use_ino              let filesystem set inode numbers (false)
  --option=direct_io            disable page cache (false)
  --option=nonempty             allow mounts over non-empty file/dir (false)
  --option=ro                   mount read-only
  -o ro,direct_io,etc           shorter version of options

  --help                        this text
  --man                         full manual page

Options can be abbreviated to single letters.

=head1 DESCRIPTION

This script will create a userspace filesystem stored entirely in a
SQL database. Only the MySQL, SQLite and PostgreSQL database engines
are currently supported. Most functionality is supported, including
hard and symbolic links, seek() and tell(), binary data, sparse files,
and the ability to unlink a file while there is still a filehandle
open on it.

The mandatory first argument is a DBI driver database source name,
such as:

 dbi:mysql:database=my_filesystem

The database must already exist, and you must have insert, update,
create table, and select privileges on it.  If you need to provide
hostname, port, username, etc, these must be included in the source
string, e.g.:

 dbi:mysql:database=my_filesystem;host=my_host;user=fred;password=xyzzy

If you request unmounting (using --unmount or -u), the first
non-option argument is interpreted as the mountpoint, not database
name.

=head1 MORE INFORMATION

This is a front end to the DBI::Filesystem module, which creates a
fully-functioning userspace filesystem on top of a relational
database. Unlike other filesystem-to-DBM mappings, such as Fuse::DBI,
this one creates and manages a specific schema designed to support
filesystem operations. If you wish to mount a filesystem on an
arbitrary DBM schema, you want Fuse::DBI, not this.

Why would you use this? The main reason is that it allows you to use
DBMs functionality such as accessibility over the network, database
replication, failover, etc. In addition, the underlying
DBI::Filesystem system can easily be extended to allow additional
functionality such as arbitrary access control rules, searchable file
and directory metadata, full-text indexing of file contents, etc.

Most filesystem functionality is implemented, including hard and soft
links, sparse files, ownership and access modes, UNIX permission
checking, and random access to binary files. The following features
are not implemented:

 * statfs -- df on the filesystem will not provide any information
             free space or other filesystem information.

 * extended attributes -- Extended attributes are not supported.

 * nanosecond times -- atime, mtime and ctime are accurate only to the
             second.

 * ioctl -- none are supported

 * poll  -- polling on the filesystem to detect events that update files
            will not work.


=head2 Fuse Notes

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

 $ git clone git://github.com/isync/perl-fuse.git
 $ cd perl-fuse
 $ perl Makefile.PL
 $ make test   (optional)
 $ sudo make install

=head1 AUTHOR

Copyright 2013, Lincoln D. Stein <lincoln.stein@gmail.com>

=head1 LICENSE

This package is distributed under the terms of the Perl Artistic
License 2.0. See http://www.perlfoundation.org/artistic_license_2_0.

=cut

use strict;
use warnings;
use DBI::Filesystem;
use File::Spec;
use Config;
use POSIX 'setsid';
use POSIX qw(SIGINT SIGTERM SIGHUP);

use Getopt::Long qw(:config no_ignore_case bundling_override);
use Pod::Usage;

my (@FuseOptions,$Module,$UnMount,$Create,$Debug,$NoDaemon,$NoThreads,$Help,$Man);


GetOptions(
    'help|h|?'     => \$Help,
    'man|m'        => \$Man,
    'create|c'     => \$Create,
    'option|o:s'   => \@FuseOptions,
    'foreground|f' => \$NoDaemon,
    'nothreads|n'  => \$NoThreads,
    'unmount|u'    => \$UnMount,
    'module|m'     => \$Module,
    'debug|d'      => \$Debug,
 ) or pod2usage(-verbose=>2);

 pod2usage(1)                          if $Help;
 pod2usage(-exitstatus=>0,-verbose=>2) if $Man;

$NoThreads  ||= check_disable_threads();
$Debug      ||= 0;

if ($UnMount) {
    my $mountpoint = shift;
    exec 'fusermount','-u',$mountpoint;
}

my $dsn        = shift or pod2usage(1);
my $mountpoint = shift or pod2usage(1);
$mountpoint    = File::Spec->rel2abs($mountpoint);

my $action = POSIX::SigAction->new(sub { warn "unmounting $mountpoint\n"; 
					 exec 'fusermount','-u',$mountpoint; });

foreach (SIGTERM,SIGINT,SIGHUP) {
    POSIX::sigaction($_=>$action) or die "Couldn't set $_ handler: $!";
}

my $options  = join(',',@FuseOptions);

become_daemon() unless $NoDaemon;

$Module ||= 'DBI::Filesystem';
eval "require $Module;1"        or die $@;
$Module->isa('DBI::Filesystem') or die "$Module does not inherit from DBI::Filesystem. Abort!\n";

my $filesystem = $Module->new($dsn,$Create);
$filesystem->mount($mountpoint,{debug=>$Debug,threaded=>!$NoThreads});

exit 0;

sub check_disable_threads {
    unless ($Config{useithreads}) {
	warn "This version of perl is not compiled for ithreads. Running with slower non-threaded version.\n";
	return 1;
    }
    if ($] >= 5.014 && $Fuse::VERSION < 0.15) {
	warn "You need Fuse version 0.15 or higher to run under this version of Perl.\n";
	warn "Threads will be disabled. Running with slower non-threaded version.\n";
	return 1;
    }

    return 0;
}

sub become_daemon {
    fork() && exit 0;
    chdir ('/');
    setsid();
    open STDIN,"</dev/null";
    fork() && exit 0;
}

__END__