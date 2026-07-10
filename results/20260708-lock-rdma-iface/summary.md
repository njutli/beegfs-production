============================================================
锁定 RDMA 接口后重启验证
起始: Wed Jul  8 11:24:01 +07 2026
次数: 5
============================================================

| 轮次 | bw (MiB/s) | clat_min (µs) | RDMA | 时间 |
|------|:----------:|:------------:|:----:|------|

### Verify 1 / 5 — Wed Jul  8 11:24:01 +07 2026
  [restart] slave storage + meta...
  [restart] 157 mgmtd (stop+start, 处理卡死)...
  [restart] 157 meta...
  [restart] client...
  [restart] mount OK, 6 targets Good ✓
  beegfs-net: 100% RDMA ✓ (3 RDMA, 0 TCP)
   Connections: RDMA: 2 (10.3.1.6:8003); 
   Connections: RDMA: 2 (10.3.1.7:8003); 
   Connections: RDMA: 2 (10.3.1.8:8003); 
  bw=889, clat_min=223µs
| 1 | 889 | 223 | ✓ | Wed Jul  8 11:28:15 +07 2026 |

### Verify 2 / 5 — Wed Jul  8 11:28:15 +07 2026
  [restart] slave storage + meta...
  [restart] 157 mgmtd (stop+start, 处理卡死)...
  [restart] 157 meta...
  [restart] client...
  [restart] mount OK, 6 targets Good ✓
  beegfs-net: 100% RDMA ✓ (3 RDMA, 0 TCP)
   Connections: RDMA: 2 (10.3.1.6:8003); 
   Connections: RDMA: 2 (10.3.1.7:8003); 
   Connections: RDMA: 2 (10.3.1.8:8003); 
  bw=897, clat_min=217µs
| 2 | 897 | 217 | ✓ | Wed Jul  8 11:32:27 +07 2026 |

### Verify 3 / 5 — Wed Jul  8 11:32:27 +07 2026
  [restart] slave storage + meta...
  [restart] 157 mgmtd (stop+start, 处理卡死)...
  [restart] 157 meta...
  [restart] client...
  [restart] mount OK, 6 targets Good ✓
  beegfs-net: 100% RDMA ✓ (3 RDMA, 0 TCP)
   Connections: RDMA: 2 (10.3.1.6:8003); 
   Connections: RDMA: 2 (10.3.1.7:8003); 
   Connections: RDMA: 2 (10.3.1.8:8003); 
  bw=904, clat_min=212µs
| 3 | 904 | 212 | ✓ | Wed Jul  8 11:36:41 +07 2026 |

### Verify 4 / 5 — Wed Jul  8 11:36:41 +07 2026
  [restart] slave storage + meta...
  [restart] 157 mgmtd (stop+start, 处理卡死)...
  [restart] 157 meta...
  [restart] client...
  [restart] mount OK, 6 targets Good ✓
  beegfs-net: 100% RDMA ✓ (3 RDMA, 0 TCP)
   Connections: RDMA: 2 (10.3.1.6:8003); 
   Connections: RDMA: 2 (10.3.1.7:8003); 
   Connections: RDMA: 2 (10.3.1.8:8003); 
  bw=898, clat_min=214µs
| 4 | 898 | 214 | ✓ | Wed Jul  8 11:40:55 +07 2026 |

### Verify 5 / 5 — Wed Jul  8 11:40:55 +07 2026
  [restart] slave storage + meta...
  [restart] 157 mgmtd (stop+start, 处理卡死)...
  [restart] 157 meta...
  [restart] client...
  [restart] mount OK, 6 targets Good ✓
  beegfs-net: 100% RDMA ✓ (3 RDMA, 0 TCP)
   Connections: RDMA: 2 (10.3.1.6:8003); 
   Connections: RDMA: 2 (10.3.1.7:8003); 
   Connections: RDMA: 2 (10.3.1.8:8003); 
  bw=909, clat_min=217µs
| 5 | 909 | 217 | ✓ | Wed Jul  8 11:45:09 +07 2026 |

============================================================
完成: Wed Jul  8 11:45:09 +07 2026
============================================================
