# 测试A-口径A round=1 20260709-163621
# 论点: 单流 QD1 下 100GbE 远没打满 -> 瓶颈=per-IO 延迟串行非带宽
# fio: 4G/256K/direct=1; multi=16; 对照 multi vs 单流
# sampler deployed to 3 slaves
# env snapshot -> /tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kA-r1-20260709-163621/env-snapshot.txt
# RDMA sentinel: seqwrite clat_min=222us (<250us => RDMA OK)

## prep: write 4G seq file
# prep done

## 测试项 (每项 fio 全程抓 3 slave IB counters + iostat)
# seqread: READ=1510 WRITE=NA MiB/s clat_min=107us clat_avg=165.21us
# seqwrite: READ=NA WRITE=832 MiB/s clat_min=190us clat_avg=263.73us
# multi-seqread: READ=7409 WRITE=NA MiB/s clat_min=126us clat_avg=529.61us
# multi-seqwrite: READ=NA WRITE=7881 MiB/s clat_min=201us clat_avg=467.39us

# cleanup: seq_dir removed
# DONE results: /tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kA-r1-20260709-163621
# commands.sh recorded
