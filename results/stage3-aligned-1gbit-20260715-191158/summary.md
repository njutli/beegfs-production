19:11:58 # Stage3 口径B (千兆限速 eno12409 TCP) 20260715-191158
19:11:58 # fio: seqread/mseqread 180s, seqwrite/mseqwrite bs=4M, rand 180s ×3, bw_log
19:11:58 # 顺序: 1-8,11-12 (layout依赖), 9-10另行重部署
19:11:59 # sampler deployed to 3 slaves
19:11:59 # env snapshot saved
19:11:59 
19:11:59 === 顺序测试 ===
19:11:59 ## prep: write 4G seq data (bs=4M)
19:13:04 # prep done
19:13:11 ## seqread: rw=read bs=256k nj=1 fsync=0 runtime=180 direct=1
19:17:00   seqread: READ=NA WRITE=NA
19:17:18 ## seqwrite: rw=write bs=4M nj=1 fsync=1 runtime= direct=1
19:18:21   seqwrite: READ=NA WRITE=NA
19:18:32 ## prep: 16 job x 4G (bs=4M)
19:28:24 ## mseqread: rw=read bs=256k nj=16 fsync=0 runtime=180 direct=1
19:44:11   mseqread: READ=NA WRITE=NA
19:44:27 ## mseqwrite: rw=write bs=4M nj=16 fsync=1 runtime= direct=1
19:54:08   mseqwrite: READ=NA WRITE=NA
19:54:19 
19:54:19 === layout ===
19:54:23 ## layout: 128job x 1G, bs=4M
20:13:45   layout: WRITE=NA
20:13:56 # layout done, cooldown 60s
20:14:56 
20:14:56 === 随机测试 ===
20:15:01 ## randread r1: rw=randread bs=256k 128job iodepth=128 180s direct=1 
20:18:02   randread r1: READ=NA WRITE=NA
20:18:16 ## randread r2: rw=randread bs=256k 128job iodepth=128 180s direct=1 
20:21:17   randread r2: READ=NA WRITE=NA
20:21:31 ## randread r3: rw=randread bs=256k 128job iodepth=128 180s direct=1 
20:24:32   randread r3: READ=NA WRITE=NA
20:24:46 ## randwrite-analysis r1: rw=randwrite bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
20:27:47   randwrite-analysis r1: READ=NA WRITE=NA
20:28:01 ## randwrite-analysis r2: rw=randwrite bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
20:31:03   randwrite-analysis r2: READ=NA WRITE=NA
20:31:17 ## randwrite-analysis r3: rw=randwrite bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
20:34:18   randwrite-analysis r3: READ=NA WRITE=NA
20:34:32 ## randrw-analysis r1: rw=randrw bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
20:37:33   randrw-analysis r1: READ=NA WRITE=NA
20:37:47 ## randrw-analysis r2: rw=randrw bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
20:40:49   randrw-analysis r2: READ=NA WRITE=NA
20:41:03 ## randrw-analysis r3: rw=randrw bs=256k 128job iodepth=128 180s direct=1 --openfiles=100
20:44:04   randrw-analysis r3: READ=NA WRITE=NA
20:44:18 ## randread-64K r1: rw=randread bs=64k 128job iodepth=128 180s direct=1 
20:47:19   randread-64K r1: READ=NA WRITE=NA
20:47:33 ## randread-64K r2: rw=randread bs=64k 128job iodepth=128 180s direct=1 
20:50:34   randread-64K r2: READ=NA WRITE=NA
20:50:48 ## randread-64K r3: rw=randread bs=64k 128job iodepth=128 180s direct=1 
20:53:49   randread-64K r3: READ=NA WRITE=NA
20:54:03 ## randread-1M r1: rw=randread bs=1M 128job iodepth=128 180s direct=1 
20:57:04   randread-1M r1: READ=NA WRITE=NA
20:57:19 ## randread-1M r2: rw=randread bs=1M 128job iodepth=128 180s direct=1 
21:00:20   randread-1M r2: READ=NA WRITE=NA
21:00:35 ## randread-1M r3: rw=randread bs=1M 128job iodepth=128 180s direct=1 
21:03:36   randread-1M r3: READ=NA WRITE=NA
21:03:46 
21:03:46 # DONE (items 1-8, 11-12)
21:03:46 # results: /tmp/beegfs-test/results/stage3-aligned-1gbit-20260715-191158
21:03:46 # NOTE: items 9-10 (验收口径) need redeploy, run separately
21:08:02 
21:08:02 === randwrite 验收口径 (fresh dir + create_on_open) ×3 ===
21:08:04 ## randwrite-fresh r1: rw=randwrite bs=256k 128job create_on_open 180s direct=1
21:11:10   randwrite-fresh r1: WRITE=111
21:11:30 ## randwrite-fresh r2: rw=randwrite bs=256k 128job create_on_open 180s direct=1
21:14:36   randwrite-fresh r2: WRITE=111
21:14:57 ## randwrite-fresh r3: rw=randwrite bs=256k 128job create_on_open 180s direct=1
21:18:04   randwrite-fresh r3: WRITE=102
21:18:23 # randwrite 验收 done
21:19:30 
21:19:30 === randrw 验收口径 (fresh dir + create_on_open) ×3 ===
21:19:32 ## randrw-fresh r1: rw=randrw bs=256k 128job create_on_open 180s direct=1
21:22:37   randrw-fresh r1: READ=53.0 WRITE=108
21:22:58 ## randrw-fresh r2: rw=randrw bs=256k 128job create_on_open 180s direct=1
21:26:04   randrw-fresh r2: READ=52.9 WRITE=108
21:26:25 ## randrw-fresh r3: rw=randrw bs=256k 128job create_on_open 180s direct=1
21:29:30   randrw-fresh r3: READ=52.9 WRITE=108
21:29:49 # randrw 验收 done
