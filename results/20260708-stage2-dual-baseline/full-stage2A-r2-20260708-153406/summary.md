============================================================
BeeGFS Full Performance Test — stage2A-r2 20260708-153406
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-stage2A-r2-20260708-153406/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=1522 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=847 MiB/s
  multi-seqread: READ=6891 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=7843 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=10209 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=9253 WRITE=NA MiB/s IOPS_R=37.0k IOPS_W=NA
  randwrite r1: READ=NA WRITE=6169 MiB/s IOPS_R=NA IOPS_W=24.7k
  randrw r1: READ=4603 WRITE=4601 MiB/s IOPS_R=18.4k IOPS_W=18.4k
### Round 2
  randread r2: READ=9263 WRITE=NA MiB/s IOPS_R=37.1k IOPS_W=NA
  randwrite r2: READ=NA WRITE=6233 MiB/s IOPS_R=NA IOPS_W=24.9k
  randrw r2: READ=4586 WRITE=4584 MiB/s IOPS_R=18.3k IOPS_W=18.3k
### Round 3
  randread r3: READ=9249 WRITE=NA MiB/s IOPS_R=37.0k IOPS_W=NA
  randwrite r3: READ=NA WRITE=6139 MiB/s IOPS_R=NA IOPS_W=24.6k
  randrw r3: READ=4569 WRITE=4567 MiB/s IOPS_R=18.3k IOPS_W=18.3k

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=4759 WRITE=NA MiB/s IOPS_R=76.1k IOPS_W=NA
  randread-64K r2: READ=4782 WRITE=NA MiB/s IOPS_R=76.5k IOPS_W=NA
  randread-64K r3: READ=4755 WRITE=NA MiB/s IOPS_R=76.1k IOPS_W=NA
### bs=256K
  randread-256K r1: READ=9254 WRITE=NA MiB/s IOPS_R=37.0k IOPS_W=NA
  randread-256K r2: READ=9250 WRITE=NA MiB/s IOPS_R=37.0k IOPS_W=NA
  randread-256K r3: READ=9252 WRITE=NA MiB/s IOPS_R=37.0k IOPS_W=NA
### bs=1M
  randread-1M r1: READ=10650 WRITE=NA MiB/s IOPS_R=10.6k IOPS_W=NA
  randread-1M r2: READ=10650 WRITE=NA MiB/s IOPS_R=10.6k IOPS_W=NA
  randread-1M r3: READ=10650 WRITE=NA MiB/s IOPS_R=10.6k IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-stage2A-r2-20260708-153406
  commands.sh generated
