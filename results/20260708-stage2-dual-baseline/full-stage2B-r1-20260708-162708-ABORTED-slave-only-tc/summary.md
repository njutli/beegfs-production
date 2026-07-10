============================================================
BeeGFS Full Performance Test — stage2B-r1 20260708-162708
============================================================
## 口径:
  mode=cold, extra_opts=
  seq: 1次; rand: 3轮; bs-sweep: 3轮

  env snapshot -> /tmp/beegfs-test/results/full-stage2B-r1-20260708-162708/env-snapshot.txt

## 顺序测试 (bs=256K)
### seqread prep (write 4G)
  seqread: READ=104 WRITE=NA MiB/s
  seqwrite: READ=NA WRITE=91.9 MiB/s
  multi-seqread: READ=301 WRITE=NA MiB/s
  multi-seqwrite: READ=NA WRITE=170 MiB/s

## 布局 (128 jobs x 1G = 128G, bs=4M)
