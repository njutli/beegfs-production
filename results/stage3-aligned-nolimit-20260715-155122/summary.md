15:51:22 # Stage3 口径A (不限速 100GbE RDMA) 20260715-155122
15:51:22 # fio: seqread/mseqread 180s, seqwrite/mseqwrite bs=4M, rand 180s ×3, bw_log
15:51:22 # 顺序: 1-8,11-12 (layout依赖), 9-10另行重部署
15:51:23 # sampler deployed to 3 slaves
15:51:24 # env snapshot saved
15:51:24 
15:51:24 === 顺序测试 ===
15:51:24 ## prep: write 4G seq data (bs=4M)
15:51:28 # prep done
15:51:32 ## seqread: rw=read bs=256k nj=1 fsync=0 runtime=180 direct=1
15:54:36   seqread: READ=NA WRITE=NA
15:54:51 ## seqwrite: rw=write bs=4M nj=1 fsync=1 runtime= direct=1
15:54:53   seqwrite: READ=NA WRITE=NA
15:55:03 ## prep: 16 job x 4G (bs=4M)
15:55:28 ## mseqread: rw=read bs=256k nj=16 fsync=0 runtime=180 direct=1
15:59:34   mseqread: READ=NA WRITE=NA
15:59:50 ## mseqwrite: rw=write bs=4M nj=16 fsync=1 runtime= direct=1
15:59:57   mseqwrite: READ=NA WRITE=NA
16:00:06 
16:00:06 === layout ===
16:00:10 ## layout: 128job x 1G, bs=4M
16:00:25   layout: WRITE=NA
16:00:34 # layout done, cooldown 60s
16:01:34 
16:01:34 === 随机测试 ===
16:01:39 ## randread r1: rw=randread bs=256k 128job iodepth=128 180s direct=1 
16:04:40   randread r1: READ=NA WRITE=NA
16:04:54 ## randread r2: rw=randread bs=256k 128job iodepth=128 180s direct=1 
16:07:55   randread r2: READ=NA WRITE=NA
16:08:09 ## randread r3: rw=randread bs=256k 128job iodepth=128 180s direct=1 
16:11:10   randread r3: READ=NA WRITE=NA
16:11:24 ## randwrite-analysis r1: rw=randwrite bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
16:14:25   randwrite-analysis r1: READ=NA WRITE=NA
16:14:39 ## randwrite-analysis r2: rw=randwrite bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
16:17:40   randwrite-analysis r2: READ=NA WRITE=NA
16:17:54 ## randwrite-analysis r3: rw=randwrite bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
16:20:55   randwrite-analysis r3: READ=NA WRITE=NA
16:21:09 ## randrw-analysis r1: rw=randrw bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
16:24:10   randrw-analysis r1: READ=NA WRITE=NA
16:24:24 ## randrw-analysis r2: rw=randrw bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
16:27:25   randrw-analysis r2: READ=NA WRITE=NA
16:27:39 ## randrw-analysis r3: rw=randrw bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
16:30:40   randrw-analysis r3: READ=NA WRITE=NA
16:30:54 ## randread-64K r1: rw=randread bs=64k 128job iodepth=128 180s direct=1 
16:33:55   randread-64K r1: READ=NA WRITE=NA
16:34:09 ## randread-64K r2: rw=randread bs=64k 128job iodepth=128 180s direct=1 
16:37:10   randread-64K r2: READ=NA WRITE=NA
16:37:24 ## randread-64K r3: rw=randread bs=64k 128job iodepth=128 180s direct=1 
16:40:25   randread-64K r3: READ=NA WRITE=NA
16:40:39 ## randread-1M r1: rw=randread bs=1M 128job iodepth=128 180s direct=1 
16:43:40   randread-1M r1: READ=NA WRITE=NA
16:43:54 ## randread-1M r2: rw=randread bs=1M 128job iodepth=128 180s direct=1 
16:46:55   randread-1M r2: READ=NA WRITE=NA
16:47:10 ## randread-1M r3: rw=randread bs=1M 128job iodepth=128 180s direct=1 
16:50:11   randread-1M r3: READ=NA WRITE=NA
16:50:21 
16:50:21 # DONE (items 1-8, 11-12)
16:50:21 # results: /tmp/beegfs-test/results/stage3-aligned-nolimit-20260715-155122
16:50:21 # NOTE: items 9-10 (验收口径) need redeploy, run separately
17:09:27 
17:09:27 === randwrite 验收口径 (fresh dir + create_on_open) ×3 ===
17:09:30 ## randwrite-fresh r1: rw=randwrite bs=256k 128job create_on_open 180s direct=1
17:12:34   randwrite-fresh r1: WRITE=6614
17:13:29 ## randwrite-fresh r2: rw=randwrite bs=256k 128job create_on_open 180s direct=1
17:16:33   randwrite-fresh r2: WRITE=6599
17:17:25 ## randwrite-fresh r3: rw=randwrite bs=256k 128job create_on_open 180s direct=1
17:20:29   randwrite-fresh r3: WRITE=6617
17:21:21 # randwrite 验收 done
17:39:23 
17:39:23 === randrw 验收口径 (fresh dir + create_on_open) ×3 ===
17:39:26 ## randrw-fresh r1: rw=randrw bs=256k 128job create_on_open 180s direct=1
17:42:30   randrw-fresh r1: READ=2487 WRITE=4183
17:43:15 ## randrw-fresh r2: rw=randrw bs=256k 128job create_on_open 180s direct=1
17:46:19   randrw-fresh r2: READ=2516 WRITE=4226
17:47:08 ## randrw-fresh r3: rw=randrw bs=256k 128job create_on_open 180s direct=1
17:50:12   randrw-fresh r3: READ=2574 WRITE=4317
17:50:57 # randrw 验收 done
