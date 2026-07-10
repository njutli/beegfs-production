# 测试B-写放大对照 20260709-170303
# 镜像(Buddy Mirror) vs 非镜像(RAID0), randwrite+randrw 各2轮
# nomirror-test created: RAID0/chunk1M/numtargets=6
# RDMA sentinel clat_min=204us

## Round 1
# mirror-randwrite-r1: READ=NA WRITE=6488 MiB/s IOPS_R=NA IOPS_W=26.0k
# mirror-randrw-r1: READ=4817 WRITE=4813 MiB/s IOPS_R=19.3k IOPS_W=19.3k
# nomirror-randwrite-r1: READ=NA WRITE=11571 MiB/s IOPS_R=NA IOPS_W=46.2k
# nomirror-randrw-r1: READ=6629 WRITE=6632 MiB/s IOPS_R=26.5k IOPS_W=26.5k

## Round 2
# mirror-randwrite-r2: READ=NA WRITE=6602 MiB/s IOPS_R=NA IOPS_W=26.4k
# mirror-randrw-r2: READ=4909 WRITE=4904 MiB/s IOPS_R=19.6k IOPS_W=19.6k
# nomirror-randwrite-r2: READ=NA WRITE=11469 MiB/s IOPS_R=NA IOPS_W=46.1k
# nomirror-randrw-r2: READ=6629 WRITE=6633 MiB/s IOPS_R=26.5k IOPS_W=26.5k

# cleanup: nomirror-test removed; root stripe untouched
# DONE results: /tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testB-writeAmp-20260709-170303
