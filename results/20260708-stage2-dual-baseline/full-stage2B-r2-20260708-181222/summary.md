============================================================
BeeGFS Full Performance Test — stage2B-r2 20260708-181222
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-stage2B-r2-20260708-181222/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=104 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=53.3 MiB/s
  multi-seqread: READ=248 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=112 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=113 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=340 WRITE=NA MiB/s IOPS_R=1358 IOPS_W=NA
  randwrite r1: READ=NA WRITE=111 MiB/s IOPS_R=NA IOPS_W=444
  randrw r1: READ=108 WRITE=106 MiB/s IOPS_R=430 IOPS_W=423
### Round 2
  randread r2: READ=340 WRITE=NA MiB/s IOPS_R=1358 IOPS_W=NA
  randwrite r2: READ=NA WRITE=111 MiB/s IOPS_R=NA IOPS_W=444
  randrw r2: READ=108 WRITE=106 MiB/s IOPS_R=431 IOPS_W=424
### Round 3
  randread r3: READ=340 WRITE=NA MiB/s IOPS_R=1360 IOPS_W=NA
  randwrite r3: READ=NA WRITE=111 MiB/s IOPS_R=NA IOPS_W=443
  randrw r3: READ=108 WRITE=106 MiB/s IOPS_R=430 IOPS_W=425

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=340 WRITE=NA MiB/s IOPS_R=5445 IOPS_W=NA
  randread-64K r2: READ=340 WRITE=NA MiB/s IOPS_R=5445 IOPS_W=NA
  randread-64K r3: READ=340 WRITE=NA MiB/s IOPS_R=5447 IOPS_W=NA
### bs=256K
  randread-256K r1: READ=340 WRITE=NA MiB/s IOPS_R=1361 IOPS_W=NA
  randread-256K r2: READ=339 WRITE=NA MiB/s IOPS_R=1357 IOPS_W=NA
  randread-256K r3: READ=340 WRITE=NA MiB/s IOPS_R=1358 IOPS_W=NA
### bs=1M
  randread-1M r1: READ=339 WRITE=NA MiB/s IOPS_R=339 IOPS_W=NA
  randread-1M r2: READ=339 WRITE=NA MiB/s IOPS_R=338 IOPS_W=NA
  randread-1M r3: READ=339 WRITE=NA MiB/s IOPS_R=339 IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-stage2B-r2-20260708-181222
  commands.sh generated
