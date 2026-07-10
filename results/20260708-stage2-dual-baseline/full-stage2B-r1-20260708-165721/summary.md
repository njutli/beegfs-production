============================================================
BeeGFS Full Performance Test — stage2B-r1 20260708-165721
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-stage2B-r1-20260708-165721/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=104 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=53.2 MiB/s
  multi-seqread: READ=302 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=113 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
  layout: WRITE=113 MiB/s

## Layout cooldown (60s)...

## 随机测试 (3轮, bs=256K)
### Round 1
  randread r1: READ=339 WRITE=NA MiB/s IOPS_R=1356 IOPS_W=NA
  randwrite r1: READ=NA WRITE=111 MiB/s IOPS_R=NA IOPS_W=444
  randrw r1: READ=108 WRITE=107 MiB/s IOPS_R=430 IOPS_W=428
### Round 2
  randread r2: READ=339 WRITE=NA MiB/s IOPS_R=1357 IOPS_W=NA
  randwrite r2: READ=NA WRITE=111 MiB/s IOPS_R=NA IOPS_W=444
  randrw r2: READ=107 WRITE=107 MiB/s IOPS_R=427 IOPS_W=428
### Round 3
  randread r3: READ=339 WRITE=NA MiB/s IOPS_R=1355 IOPS_W=NA
  randwrite r3: READ=NA WRITE=111 MiB/s IOPS_R=NA IOPS_W=445
  randrw r3: READ=108 WRITE=107 MiB/s IOPS_R=430 IOPS_W=429

## Block Size Sweep (randread, 3 rounds)
### bs=64K
  randread-64K r1: READ=340 WRITE=NA MiB/s IOPS_R=5444 IOPS_W=NA
  randread-64K r2: READ=340 WRITE=NA MiB/s IOPS_R=5438 IOPS_W=NA
  randread-64K r3: READ=340 WRITE=NA MiB/s IOPS_R=5440 IOPS_W=NA
### bs=256K
  randread-256K r1: READ=340 WRITE=NA MiB/s IOPS_R=1358 IOPS_W=NA
  randread-256K r2: READ=339 WRITE=NA MiB/s IOPS_R=1355 IOPS_W=NA
  randread-256K r3: READ=339 WRITE=NA MiB/s IOPS_R=1355 IOPS_W=NA
### bs=1M
  randread-1M r1: READ=342 WRITE=NA MiB/s IOPS_R=341 IOPS_W=NA
  randread-1M r2: READ=341 WRITE=NA MiB/s IOPS_R=340 IOPS_W=NA
  randread-1M r3: READ=341 WRITE=NA MiB/s IOPS_R=340 IOPS_W=NA

## Cleanup
  Test files removed.

DONE
  Results: /tmp/beegfs-test/results/full-stage2B-r1-20260708-165721
  commands.sh generated
