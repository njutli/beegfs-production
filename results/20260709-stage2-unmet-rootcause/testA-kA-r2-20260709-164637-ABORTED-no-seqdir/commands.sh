#!/bin/bash
# 测试A-口径A round=2 20260709-164637
# fio params (match bench-full.sh run_seq, cold direct=1)
SEQ_DIR=/mnt/beegfs/seq_dir
fio --name=prep --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --direct=1
fio --name=seqread --directory=$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G --direct=1
fio --name=seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --direct=1 --end_fsync=1
fio --name=multi-seqread --directory=$SEQ_DIR --rw=read --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --direct=1
fio --name=multi-seqwrite --directory=$SEQ_DIR --rw=write --refill_buffers --bs=256K --size=4G --numjobs=16 --group_reporting --direct=1 --end_fsync=1
# concurrent sampling on 3 slaves: bash /tmp/ib-iostat-sampler.sh <prefix> 600
#   infiniband counters: /sys/class/infiniband/mlx5_*/ports/*/counters/port_xmit_data|port_rcv_data (unit=4B)
#   iostat -x 1 600
