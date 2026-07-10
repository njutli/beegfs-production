# 测试A-口径B round=1 20260709-175037
# 论点: 单流 QD1 + 镜像双写 + 千兆 RTT 延迟串行, 链路未打满
# fio: 1G/256K/direct=1/end_fsync=1; multi=16; 对照 multi vs 单流
# env snapshot -> env-snapshot.txt
# seqwrite: WRITE=53.0 MiB/s clat_min=4568us clat_avg=4675.73us
# multi-seqwrite: WRITE=113 MiB/s clat_min=NAus clat_avg=NAus
# DONE results: /tmp/beegfs-test/results/20260709-stage2-unmet-rootcause/testA-kB-r1-20260709-175037
