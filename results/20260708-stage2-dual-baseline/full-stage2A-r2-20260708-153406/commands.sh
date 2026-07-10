#!/bin/bash
# BeeGFS Full Test Commands: stage2A-r2
# Mode: cold

# Sequential tests (bs=256K)
fio --name=prep --directory=/mnt/beegfs/seq_dir --rw=write --bs=256K --size=4G --direct=1
fio --name=seqread --directory=/mnt/beegfs/seq_dir --rw=read --bs=256K --size=4G --direct=1
fio --name=seqwrite --directory=/mnt/beegfs/seq_dir --rw=write --bs=256K --size=4G --end_fsync=1 --direct=1
fio --name=multi-seqread --directory=/mnt/beegfs/seq_dir --rw=read --bs=256K --size=4G --numjobs=16 --group_reporting --direct=1
fio --name=multi-seqwrite --directory=/mnt/beegfs/seq_dir --rw=write --bs=256K --size=4G --numjobs=16 --group_reporting --end_fsync=1 --direct=1

# Layout (128 jobs x 1G, bs=4M)
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G --bs=4M     --rw=write --numjobs=128 --fallocate=none --group_reporting --end_fsync=1 --direct=1

# Random tests (bs=256K, 3 rounds, 60s each)
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256K --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256K --rw=randwrite --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G     --bs=256K --rw=randrw --ioengine=libaio --iodepth=128 --numjobs=128     --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s

# Block size sweep (randread, bs=64K/256K/1M)
for bs in 64K 256K 1M; do
  fio --directory=/mnt/beegfs/test_dir --name=storage_test --filesize=1G --size=1G       --bs=${bs} --rw=randread --ioengine=libaio --iodepth=128 --numjobs=128       --direct=1 --fallocate=none --openfiles=128 --group_reporting --time_based --runtime=60s
done
