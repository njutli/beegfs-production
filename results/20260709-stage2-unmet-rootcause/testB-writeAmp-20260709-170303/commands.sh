#!/bin/bash
# 测试B-写放大对照 20260709-170303
# 镜像(/mnt/beegfs/test_dir, Buddy Mirror) vs 非镜像(/mnt/beegfs/nomirror-test, RAID0)
beegfs-ctl --setpattern --pattern=raid0 --chunksize=1m --numtargets=6 /mnt/beegfs/nomirror-test
beegfs-ctl --getentryinfo --entry=/mnt/beegfs/nomirror-test
# randwrite (128,256K,60s) on mirror:
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# randwrite on nomirror:
fio --directory=/mnt/beegfs/nomirror-test --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# randrw (128,256K,60s) on mirror:
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# randrw on nomirror:
fio --directory=/mnt/beegfs/nomirror-test --name=storage_test --filesize=1G --size=1G --bs=256K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128 --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
# concurrent: iostat -x 1 on 3 slaves
rm -rf /mnt/beegfs/nomirror-test
