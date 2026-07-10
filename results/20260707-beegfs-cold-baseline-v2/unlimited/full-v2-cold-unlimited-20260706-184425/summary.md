============================================================
BeeGFS Full Performance Test — v2-cold-unlimited 20260706-184425
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-v2-cold-unlimited-20260706-184425/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=1585 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=835 MiB/s
  multi-seqread: READ=6874 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=8214 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=10240 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=8227 WRITE=NA MiB/s IOPS_R=32.9k IOPS_W=NA
  randwrite r1: READ=NA WRITE=6138 MiB/s IOPS_R=NA IOPS_W=24.6k
  randrw r1: READ=4602 WRITE=4599 MiB/s IOPS_R=18.4k IOPS_W=18.4k
### Round 2
  randread r2: READ=8230 WRITE=NA MiB/s IOPS_R=32.9k IOPS_W=NA
  randwrite r2: READ=NA WRITE=6157 MiB/s IOPS_R=NA IOPS_W=24.6k
  randrw r2: READ=4681 WRITE=4679 MiB/s IOPS_R=18.7k IOPS_W=18.7k
### Round 3
  randread r3: READ=8234 WRITE=NA MiB/s IOPS_R=32.9k IOPS_W=NA
  randwrite r3: READ=NA WRITE=6331 MiB/s IOPS_R=NA IOPS_W=25.3k
  randrw r3: READ=4616 WRITE=4613 MiB/s IOPS_R=18.5k IOPS_W=18.5k

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=4789 WRITE=NA MiB/s IOPS_R=76.6k IOPS_W=NA
  randread-64K r2: READ=4771 WRITE=NA MiB/s IOPS_R=76.3k IOPS_W=NA
  randread-64K r3: READ=4792 WRITE=NA MiB/s IOPS_R=76.7k IOPS_W=NA
### bs=256K
  randread-256K r1: READ=8219 WRITE=NA MiB/s IOPS_R=32.9k IOPS_W=NA
  randread-256K r2: READ=8224 WRITE=NA MiB/s IOPS_R=32.9k IOPS_W=NA
  randread-256K r3: READ=8227 WRITE=NA MiB/s IOPS_R=32.9k IOPS_W=NA
### bs=1M
  randread-1M r1: READ=8807 WRITE=NA MiB/s IOPS_R=8806 IOPS_W=NA
  randread-1M r2: READ=8800 WRITE=NA MiB/s IOPS_R=8800 IOPS_W=NA
  randread-1M r3: READ=8820 WRITE=NA MiB/s IOPS_R=8820 IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-v2-cold-unlimited-20260706-184425
  commands.sh generated
