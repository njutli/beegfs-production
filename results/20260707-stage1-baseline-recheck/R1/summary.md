============================================================
BeeGFS Full Performance Test — stage1-rechk-r1 20260707-124837
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-stage1-rechk-r1-20260707-124837/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=1484 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=479 MiB/s
  multi-seqread: READ=6885 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=7406 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=10097 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=9235 WRITE=NA MiB/s IOPS_R=36.9k IOPS_W=NA
  randwrite r1: READ=NA WRITE=6088 MiB/s IOPS_R=NA IOPS_W=24.4k
  randrw r1: READ=4500 WRITE=4501 MiB/s IOPS_R=18.0k IOPS_W=18.0k
### Round 2
  randread r2: READ=9225 WRITE=NA MiB/s IOPS_R=36.9k IOPS_W=NA
  randwrite r2: READ=NA WRITE=6107 MiB/s IOPS_R=NA IOPS_W=24.4k
  randrw r2: READ=4536 WRITE=4537 MiB/s IOPS_R=18.1k IOPS_W=18.1k
### Round 3
  randread r3: READ=9229 WRITE=NA MiB/s IOPS_R=36.9k IOPS_W=NA
  randwrite r3: READ=NA WRITE=5992 MiB/s IOPS_R=NA IOPS_W=24.0k
  randrw r3: READ=4550 WRITE=4552 MiB/s IOPS_R=18.2k IOPS_W=18.2k

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=5094 WRITE=NA MiB/s IOPS_R=81.5k IOPS_W=NA
  randread-64K r2: READ=5476 WRITE=NA MiB/s IOPS_R=87.6k IOPS_W=NA
  randread-64K r3: READ=5407 WRITE=NA MiB/s IOPS_R=86.5k IOPS_W=NA
### bs=256K
  randread-256K r1: READ=9234 WRITE=NA MiB/s IOPS_R=36.9k IOPS_W=NA
  randread-256K r2: READ=9231 WRITE=NA MiB/s IOPS_R=36.9k IOPS_W=NA
  randread-256K r3: READ=9230 WRITE=NA MiB/s IOPS_R=36.9k IOPS_W=NA
### bs=1M
  randread-1M r1: READ=10547 WRITE=NA MiB/s IOPS_R=10.6k IOPS_W=NA
  randread-1M r2: READ=10547 WRITE=NA MiB/s IOPS_R=10.6k IOPS_W=NA
  randread-1M r3: READ=10547 WRITE=NA MiB/s IOPS_R=10.6k IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-stage1-rechk-r1-20260707-124837
  commands.sh generated
