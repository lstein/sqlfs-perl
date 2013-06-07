#!/bin/sh

sync
sudo /bin/sh -c 'echo 3 > /proc/sys/vm/drop_caches'
echo "write local"
#dd if=/tmp/linux_3.2.0.orig.tar.gz of=/tmp/sqlfs/linux.tar.gz bs=4096
dd if=/tmp/linux_3.2.0.orig.tar.gz of=$HOME/linux.tar.gz bs=4096
#dd if=/tmp/linux_3.2.0.orig.tar.gz of=/net/cubox/Backups/linux.tar.gz bs=4096

sync
sudo /bin/sh -c 'echo 3 > /proc/sys/vm/drop_caches'
echo "read local"
#dd if=/tmp/sqlfs/linux.tar.gz of=/dev/null bs=4096
dd if=$HOME/linux.tar.gz of=/dev/null bs=4096
#dd if=/net/cubox/Backups//linux.tar.gz of=/dev/null bs=4096