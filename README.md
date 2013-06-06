sqlfs-perl
==========

Create a fully functional user filesystem withinin a SQL database.

Unlike other filesystem-to-DBM mappings, such as Fuse::DBI, this one
creates and manages a specific schema designed to support filesystem
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

Command-Line Tool
=================

The sqlfs.pl command will be installed along with this library. Its brief symopsis is:

 Usage:
     % sqlfs.pl [options] dbi:<driver_name>:database=<name>;<other_args> <mount point>

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

Author and License Information
==============================

Copyright 2013, Lincoln D. Stein <lincoln.stein@gmail.com>

This package is distributed under the terms of the Perl Artistic
License 2.0. See http://www.perlfoundation.org/artistic_license_2_0.
