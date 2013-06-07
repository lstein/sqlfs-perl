sqlfs-perl
==========

This creates a fully functional user filesystem within in a SQL
database. It supports the MySQL, PostgreSQL and SQLite databases, and
can be extended to support any other relational database that has a
Perl DBI driver.

Most filesystem functionality is implemented, including hard and soft
links, sparse files, ownership and access modes, UNIX permission
checking and random access to binary files. Very large files (up to
multiple gigabytes) are supported without performance degradation (see
performance notes below).

Why would you use this? The main reason is that it allows you to use
DBMs functionality such as accessibility over the network, database
replication, failover, etc. In addition, the underlying
DBI::Filesystem module can be extended via subclassing to allow
additional functionality such as arbitrary access control rules,
searchable file and directory metadata, full-text indexing of file
contents, etc.

Using the Module
================

Before mounting the DBMS, you must have created the database and
assigned yourself sufficient privileges to read and write to it. You
must also create an empty directory to serve as the mount point.

* A SQLite database:

This is very simple.

 # make the mount point
 $ mkdir /tmp/sqlfs

 # make an empty SQLite database (not really necessary)
 $ touch /home/myself/filesystem.sqlite

 # run the sqlfs.pl command line tool with the --initialize option
 $ sqlfs.pl dbi:SQLite:/home/lstein/filesystem.sqlite --initialize /tmp/sqlfs
 WARNING: any existing data will be overwritten. Proceed? [y/N] y

 # now start reading/writing to the filesystem
 $ echo 'hello world!' > /tmp/sqlfs/hello.txt
 $ mkdir /tmp/sqlfs/subdir
 $ mv /tmp/sqlfs/hello.txt /tmp/sqlfs/subdir
 $ ls -l /tmp/sqlfs/subdir
 total 1
 -rw-rw-r-- 1 myself myself 13 Jun  7 06:23 hello.txt
 $ cat /tmp/sqlfs/subdir/hello.txt
 Hello world!

 # unmount the filesystem when you are done
 $ sqlfs.pl -u /tmp/sqlfs

To mount the filesystem again, simply run sqlfs.pl without the
--initialize option.

* A MySql database:

You will need to use the mysqladmin tool to create the database and
grant yourself privileges on it.

 $ mysqladmin -uroot -p create filesystem
 Enter password: 

 $ mysql -uroot -p filesystem
 Enter password: 
 Welcome to the MySQL monitor.  Commands end with ; or \g.
 ...
 mysql> grant all privileges on filesystem.* to myself identified by 'foobar';
 mysql> flush privileges;
 mysql> quit

Create the mountpoint, and use the sqlfs.pl script to initialize and
mount the database as before:

 $ mkdir /tmp/sqlfs
 $ sqlfs.pl 'dbi:mysql:dbname=filesystem;user=myself;password=foobar' --initialize /tmp/sqlfs
 $ echo 'hello world!' > /tmp/sqlfs/hello.txt
 ... etc ... 

Note that this will work across the network using the extended DBI
data source syntax (see the DBD::mysql manual page):

 $ sqlfs.pl 'dbi:mysql:filesystem;host=roxy.foo.com;user=myself;password=foobar' /tmp/sqlfs

Unmount the filesystem with the -u option:

 $ sqlfs.pl -u /tmp/sqlfs

* A PostgreSQL database

Assuming that your login already has the ability to manage PostgreSQL
databases, creating the database is a one-step process:

 $ createdb filesystem

Now create the mountpoint and use sqlfs.pl to initialize and mount
it:

 $ sqlfs.pl 'dbi:Pg:dbname=filesystem' --initialize /tmp/sqlfs
 WARNING: any existing data will be overwritten. Proceed? [y/N] y
 
 $ echo 'hello world!' > /tmp/sqlfs/hello.txt
 ... etc ... 

 # unmount the filesystem when no longer needed
 # sqlfs.pl -u /tmp/sqlfs

Command-Line Tool
=================

The sqlfs.pl has a number of options listed here:

 Usage:
     % sqlfs.pl [options] dbi:<driver_name>:dbname=<name>;<other_args> <mount point>

    Options:

      --initialize                  initialize an empty filesystem
      --quiet                       don't ask for confirmation of initialization
      --unmount                     unmount the indicated directory
      --foreground                  remain in foreground (false)
      --nothreads                   disable threads (false)
      --debug                       enable Fuse debugging messages
      --module=<ModuleName>         Use a subclass of DBI::Filesystem

      --option=allow_other          allow other accounts to access filesystem (false)
      --option=default_permissions  enable permission checking by kernel (false)
      --option=fsname=<name>        set filesystem name (none)
      --option=use_ino              let filesystem set inode numbers (false)
      --option=direct_io            disable page cache (false)
      --option=nonempty             allow mounts over non-empty file/dir (false)
      --option=ro                   mount read-only
      -o ro,direct_io,etc           shorter version of options

      --help                        this text
      --man                         full manual page

    Options can be abbreviated to single letters.

More information can be obtained by passing the sqlfs.pl command the
--man option.

System Performance
==================

You can expect write performance roughly 10-fold slower than a local
ext3 filesystem and roughly half the speed of an NFS filesystem
mounted on a gigabit LAN. Read performance is roughly 

 * ext3 write/read

 $ sync; dd if=~/build/linux_3.2.0.orig.tar.gz of=~/linux.tar.gz bs=4096
 24077+1 records in
 24077+1 records out
 98621205 bytes (99 MB) copied, 0.627663 s, 157 MB/s

 $ sudo /bin/sh -c 'echo 3 > /proc/sys/vm/drop_caches'
 $ sync; dd if=~/linux.tar.gz of=/dev/null bs=4096
 24077+1 records in
 24077+1 records out
 98621205 bytes (99 MB) copied, 1.60981 s, 61.3 MB/s

 * SQLite benchmarking:

 $ sync; dd if=~/build/linux_3.2.0.orig.tar.gz of=/tmp/sqlfs/linux.tar.gz bs=4096
 24077+1 records in
 24077+1 records out
 98621205 bytes (99 MB) copied, 7.39544 s, 13.3 MB/s

 $ sudo /bin/sh -c 'echo 3 > /proc/sys/vm/drop_caches'
 $ sync; dd if=/tmp/sqlfs/linux.tar.gz of=/dev/null bs=4096
 24077+1 records in
 24077+1 records out
 98621205 bytes (99 MB) copied, 6.66609 s, 14.8 MB/s

Author and License Information
==============================

Copyright 2013, Lincoln D. Stein <lincoln.stein@gmail.com>

This package is distributed under the terms of the Perl Artistic
License 2.0. See http://www.perlfoundation.org/artistic_license_2_0.
