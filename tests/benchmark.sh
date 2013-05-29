#!/bin/sh

sync
sudo /bin/sh -c 'echo 3 > /proc/sys/vm/drop_caches'
dd if=/home/lstein/benchmark.wmv of=foo/test.wmv bs=4096