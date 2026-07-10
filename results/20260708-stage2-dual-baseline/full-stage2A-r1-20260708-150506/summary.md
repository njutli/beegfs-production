============================================================
BeeGFS Full Performance Test — stage2A-r1 20260708-150506
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-stage2A-r1-20260708-150506/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=1509 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=832 MiB/s
  multi-seqread: READ=7333 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=7619 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=10189 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=10752 WRITE=NA MiB/s IOPS_R=43.1k IOPS_W=NA
  randwrite r1: READ=NA WRITE=6128 MiB/s IOPS_R=NA IOPS_W=24.5k
  randrw r1: READ=4694 WRITE=4688 MiB/s IOPS_R=18.8k IOPS_W=18.8k
### Round 2
  randread r2: READ=10752 WRITE=NA MiB/s IOPS_R=43.2k IOPS_W=NA
  randwrite r2: READ=NA WRITE=6147 MiB/s IOPS_R=NA IOPS_W=24.6k
  randrw r2: READ=4728 WRITE=4722 MiB/s IOPS_R=18.9k IOPS_W=18.9k
### Round 3
  randread r3: READ=10752 WRITE=NA MiB/s IOPS_R=43.2k IOPS_W=NA
  randwrite r3: READ=NA WRITE=6058 MiB/s IOPS_R=NA IOPS_W=24.2k
  randrw r3: READ=4691 WRITE=4685 MiB/s IOPS_R=18.8k IOPS_W=18.7k

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=5535 WRITE=NA MiB/s IOPS_R=88.6k IOPS_W=NA
  randread-64K r2: READ=4757 WRITE=NA MiB/s IOPS_R=76.1k IOPS_W=NA
  randread-64K r3: READ=4775 WRITE=NA MiB/s IOPS_R=76.4k IOPS_W=NA
### bs=256K
  randread-256K r1: READ=10752 WRITE=NA MiB/s IOPS_R=43.2k IOPS_W=NA
  randread-256K r2: READ=10752 WRITE=NA MiB/s IOPS_R=43.2k IOPS_W=NA
  randread-256K r3: READ=10752 WRITE=NA MiB/s IOPS_R=43.1k IOPS_W=NA
### bs=1M
  randread-1M r1: READ=11571 WRITE=NA MiB/s IOPS_R=11.6k IOPS_W=NA
  randread-1M r2: READ=11571 WRITE=NA MiB/s IOPS_R=11.6k IOPS_W=NA
  randread-1M r3: READ=11571 WRITE=NA MiB/s IOPS_R=11.6k IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-stage2A-r1-20260708-150506
  commands.sh generated
