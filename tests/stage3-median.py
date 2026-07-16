#!/usr/bin/env python3
"""Stage3 口径A 稳态中位数计算 — 从 bw_log 文件提取逐秒瞬时带宽，截开头1/4，取中位数"""
import glob, statistics, os, re
from collections import defaultdict

RESULTS_DIR = "/tmp/beegfs-test/results/stage3-aligned-nolimit-20260715-155122"
BW_LOG_DIR = "/tmp/beegfs-bw"

def median_bw_single(prefix):
    """单 job 项：1 个 bw_log 文件"""
    files = glob.glob(f"{BW_LOG_DIR}/{prefix}_bw.*.log")
    if not files:
        # try results dir
        files = glob.glob(f"{RESULTS_DIR}/{prefix}/*_bw.*.log")
    if not files:
        return None, None
    read_vals = []
    write_vals = []
    for f in files:
        for line in open(f):
            parts = line.strip().split(',')
            if len(parts) < 3:
                continue
            # 按秒对齐
            ts = int(parts[0]) // 1000
            bw = float(parts[1])
            d = int(parts[2])  # 0=read, 1=write
            if d == 0:
                read_vals.append(bw)
            else:
                write_vals.append(bw)
    rd = wr = None
    if read_vals:
        n = len(read_vals)
        steady = read_vals[n//4:]
        rd = round(statistics.median(steady) / 1024, 1)
    if write_vals:
        n = len(write_vals)
        steady = write_vals[n//4:]
        wr = round(statistics.median(steady) / 1024, 1)
    return rd, wr

def median_bw_multi(prefix, item_dir=None):
    """128 job 项：128 个 bw_log 文件，按秒聚合后取中位数"""
    # 只读 BW_LOG_DIR，避免和 RESULTS_DIR 重复读取
    files = glob.glob(f"{BW_LOG_DIR}/{prefix}_bw.*.log")
    if not files:
        files = glob.glob(f"{RESULTS_DIR}/{item_dir}/{prefix}_bw.*.log") if item_dir else []
    if not files:
        return None, None
    ts_dir = defaultdict(lambda: [0.0, 0.0])
    for f in files:
        for line in open(f):
            parts = line.strip().split(',')
            if len(parts) < 3:
                continue
            # 按秒对齐：各 job 时间戳略有偏差（999ms vs 1000ms），必须 //1000 聚合
            ts = int(parts[0]) // 1000
            bw = float(parts[1])
            d = int(parts[2])
            ts_dir[ts][d] += bw
    # sort by timestamp
    sorted_ts = sorted(ts_dir.keys())
    read_vals = [ts_dir[ts][0] for ts in sorted_ts]
    write_vals = [ts_dir[ts][1] for ts in sorted_ts if ts_dir[ts][1] > 0]
    rd = wr = None
    if read_vals:
        n = len(read_vals)
        steady = read_vals[n//4:]
        rd = round(statistics.median(steady) / 1024, 1)
    if write_vals:
        n = len(write_vals)
        steady = write_vals[n//4:]
        wr = round(statistics.median(steady) / 1024, 1)
    return rd, wr

def fio_avg(item_dir, name):
    """从 fio 原始输出提取平均 bw"""
    fio_file = f"{RESULTS_DIR}/{item_dir}/fio-{name}.txt"
    if not os.path.exists(fio_file):
        return None, None
    content = open(fio_file).read()
    rd = wr = None
    m = re.search(r'READ: bw=([0-9.]+)(MiB|GiB)/s', content)
    if m:
        rd = float(m.group(1))
        if m.group(2) == 'GiB':
            rd = round(rd * 1024, 1)
    m = re.search(r'WRITE: bw=([0-9.]+)(MiB|GiB)/s', content)
    if m:
        wr = float(m.group(1))
        if m.group(2) == 'GiB':
            wr = round(wr * 1024, 1)
    return rd, wr

# Items: (name, item_dir, bw_log_prefix, type)
items = [
    ("seqread",          "seqread",          "seqread",          "single"),
    ("seqwrite",         "seqwrite",         "seqwrite",         "single"),
    ("mseqread",         "mseqread",         "mseqread",         "multi"),
    ("mseqwrite",        "mseqwrite",        "mseqwrite",        "multi"),
    ("layout",           "layout",           "layout",           "multi"),
    ("randread r1",      "randread-r1",      "randread-r1",      "multi"),
    ("randread r2",      "randread-r2",      "randread-r2",      "multi"),
    ("randread r3",      "randread-r3",      "randread-r3",      "multi"),
    ("randwrite-analysis r1", "randwrite-analysis-r1", "randwrite-analysis-r1", "multi"),
    ("randwrite-analysis r2", "randwrite-analysis-r2", "randwrite-analysis-r2", "multi"),
    ("randwrite-analysis r3", "randwrite-analysis-r3", "randwrite-analysis-r3", "multi"),
    ("randrw-analysis r1", "randrw-analysis-r1", "randrw-analysis-r1", "multi"),
    ("randrw-analysis r2", "randrw-analysis-r2", "randrw-analysis-r2", "multi"),
    ("randrw-analysis r3", "randrw-analysis-r3", "randrw-analysis-r3", "multi"),
    ("randread-64K r1",  "randread-64K-r1",  "randread-64K-r1",  "multi"),
    ("randread-64K r2",  "randread-64K-r2",  "randread-64K-r2",  "multi"),
    ("randread-64K r3",  "randread-64K-r3",  "randread-64K-r3",  "multi"),
    ("randread-1M r1",   "randread-1M-r1",   "randread-1M-r1",   "multi"),
    ("randread-1M r2",   "randread-1M-r2",   "randread-1M-r2",   "multi"),
    ("randread-1M r3",   "randread-1M-r3",   "randread-1M-r3",   "multi"),
    ("randwrite-fresh r1", "randwrite-fresh-r1", "randwrite-fresh-r1", "multi"),
    ("randwrite-fresh r2", "randwrite-fresh-r2", "randwrite-fresh-r2", "multi"),
    ("randwrite-fresh r3", "randwrite-fresh-r3", "randwrite-fresh-r3", "multi"),
    ("randrw-fresh r1",  "randrw-fresh-r1",  "randrw-fresh-r1",  "multi"),
    ("randrw-fresh r2",  "randrw-fresh-r2",  "randrw-fresh-r2",  "multi"),
    ("randrw-fresh r3",  "randrw-fresh-r3",  "randrw-fresh-r3",  "multi"),
]

print("=" * 80)
print(f"{'测试项':<28} {'fio平均 R':>10} {'fio平均 W':>10} {'稳态中位 R':>10} {'稳态中位 W':>10}")
print("=" * 80)

for name, item_dir, prefix, typ in items:
    fio_rd, fio_wr = fio_avg(item_dir, name.split()[0] if 'r' not in name.split()[-1] else '-'.join(name.split()[:-1]))
    # Better: just use the item_dir to find the fio file
    fio_files = glob.glob(f"{RESULTS_DIR}/{item_dir}/fio-*.txt")
    if fio_files:
        content = open(fio_files[0]).read()
        m = re.search(r'READ: bw=([0-9.]+)(MiB|GiB)/s', content)
        fio_rd = float(m.group(1)) if m else None
        if m and m.group(2) == 'GiB':
            fio_rd = round(fio_rd * 1024, 1)
        m = re.search(r'WRITE: bw=([0-9.]+)(MiB|GiB)/s', content)
        fio_wr = float(m.group(1)) if m else None
        if m and m.group(2) == 'GiB':
            fio_wr = round(fio_wr * 1024, 1)
    else:
        fio_rd = fio_wr = None

    if typ == "single":
        med_rd, med_wr = median_bw_single(prefix)
    else:
        med_rd, med_wr = median_bw_multi(prefix, item_dir)

    rd_str = f"{fio_rd:>10.1f}" if fio_rd else f"{'NA':>10}"
    wr_str = f"{fio_wr:>10.1f}" if fio_wr else f"{'NA':>10}"
    mrd_str = f"{med_rd:>10.1f}" if med_rd else f"{'NA':>10}"
    mwr_str = f"{med_wr:>10.1f}" if med_wr else f"{'NA':>10}"
    print(f"{name:<28} {rd_str} {wr_str} {mrd_str} {mwr_str}")

print("=" * 80)
