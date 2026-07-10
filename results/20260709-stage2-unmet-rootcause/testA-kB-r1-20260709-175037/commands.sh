#!/bin/bash
# 测试A-口径B round=1 20260709-175037
SEQ_DIR=/mnt/beegfs/seq_dir
fio --name=seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=1G --direct=1 --end_fsync=1
fio --name=multi-seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=1G --numjobs=16 --group_reporting --direct=1 --end_fsync=1
# concurrent sar -n DEV 1 on 4 nodes eno12409
