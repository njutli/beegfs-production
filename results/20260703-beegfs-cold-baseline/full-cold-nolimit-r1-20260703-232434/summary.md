============================================================
BeeGFS Full Performance Test — cold-nolimit-r1 20260703-232434
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-cold-nolimit-r1-20260703-232434/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=565 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=335 MiB/s
  multi-seqread: READ=6311 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=1677 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=1640 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=10650 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randwrite r1: READ=NA WRITE=1629 MiB/s IOPS_R=NA IOPS_W=NA
  randrw r1: READ=1582 WRITE=1578 MiB/s IOPS_R=NA IOPS_W=NA
### Round 2
  randread r2: READ=10650 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randwrite r2: READ=NA WRITE=1629 MiB/s IOPS_R=NA IOPS_W=NA
  randrw r2: READ=1583 WRITE=1579 MiB/s IOPS_R=NA IOPS_W=NA
### Round 3
  randread r3: READ=10650 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randwrite r3: READ=NA WRITE=1630 MiB/s IOPS_R=NA IOPS_W=NA
  randrw r3: READ=1582 WRITE=1577 MiB/s IOPS_R=NA IOPS_W=NA

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=4938 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randread-64K r2: READ=5056 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randread-64K r3: READ=4670 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
### bs=256K
  randread-256K r1: READ=10650 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randread-256K r2: READ=10650 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randread-256K r3: READ=10650 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
### bs=1M
  randread-1M r1: READ=12698 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randread-1M r2: READ=12698 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA
  randread-1M r3: READ=12698 WRITE=NA MiB/s IOPS_R=NA IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-cold-nolimit-r1-20260703-232434
  commands.sh generated
