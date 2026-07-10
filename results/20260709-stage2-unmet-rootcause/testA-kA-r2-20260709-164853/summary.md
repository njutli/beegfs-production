# 测试A-口径A round=2 20260709-164853
# 论点: 单流 QD1 下 100GbE 远没打满 -> 瓶颈=per-IO 延迟串行非带宽
# fio: 4G/256K/direct=1; multi=16; 对照 multi vs 单流
# sampler deployed to 3 slaves
# env snapshot -> /tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kA-r2-20260709-164853/env-snapshot.txt
# RDMA sentinel: seqwrite clat_min=205us (<250us => RDMA OK)

## prep: write 4G seq file
# prep done

## 测试项 (每项 fio 全程抓 3 slave IB counters + iostat)
# seqread: READ=1415 WRITE=NA MiB/s clat_min=123us clat_avg=176.32us
# seqwrite: READ=NA WRITE=854 MiB/s clat_min=183us clat_avg=255.88us
# multi-seqread: READ=6869 WRITE=NA MiB/s clat_min=141us clat_avg=574.70us
# multi-seqwrite: READ=NA WRITE=8271 MiB/s clat_min=212us clat_avg=445.49us

# cleanup: seq_dir removed
# DONE results: /tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kA-r2-20260709-164853
# commands.sh recorded
