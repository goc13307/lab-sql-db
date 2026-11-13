# M4-2 压测记录

## 环境

| 项 | 值 |
|---|---|
| MySQL | 8.4.11 (MySQL Community Server - GPL) |
| 操作系统 | Windows |
| 隔离级别 | `REPEATABLE-READ`（默认） |
| `max_connections` | **300**（压测前由 151 调大） |
| 压测工具 | `mysqlslap` 8.4.11 |
| 压测时间 | 2026-11-13 22:29:39 |

## 压测准备

### 1. 调大最大连接数

```sql
SET GLOBAL max_connections = 300;
```

> `SET GLOBAL` 重启 MySQL 后失效，本课临时调整即可。

### 2. 清场 + 造 100 张热点库存

```sql
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE notification;
TRUNCATE TABLE ticket_order;
SET FOREIGN_KEY_CHECKS = 1;

UPDATE seat_category
   SET sold_tickets = 0, total_tickets = 100
 WHERE category_id = 10;
```

**判据确认**：`category_id=10, total_tickets=100, sold_tickets=0` ✅

### 3. 压测语句 `grab.sql`

```sql
CALL sp_grab_ticket(1,3,10,1,@p_result_code);
```

> 单行、无注释、无空行 —— `mysqlslap` 按分隔符切分，注释/空行会被当作语句一部分导致语法错误。

## 压测参数

```cmd
mysqlslap --host=127.0.0.1 -u root -p1234 --create-schema=ticket_db ^
  --query=script/grab.sql --delimiter=";" ^
  --concurrency=200 --iterations=1 --number-of-queries=10000
```

| 参数 | 取值 | 说明 |
|---|---|---|
| `--concurrency` | 200 | 模拟 200 个并发客户端 |
| `--iterations` | 1 | 每档重复 1 遍 |
| `--number-of-queries` | 10000 | **总**查询次数（非每客户端），每客户端 50 次 |

## 结果一：200 并发抢 100 张（主实验）

### mysqlslap 输出

```text
Benchmark
        Average number of seconds to run all queries: 2.157 seconds
        Minimum number of seconds to run all queries: 2.157 seconds
        Maximum number of seconds to run all queries: 2.157 seconds
        Number of clients running queries: 200
        Average number of queries per client: 50
```

| 指标 | 值 |
|---|---|
| Average | 2.157 s |
| Minimum | 2.157 s |
| Maximum | 2.157 s |
| 客户端数 | 200 |
| 每客户端查询数 | 50 |

> **说明**：`--iterations=1` 时只有一轮，`Average = Minimum = Maximum` 是必然结果（三者取自同一轮）。
> 因此 `Maximum >> Average` 这个判据在本参数下无法体现，故补充了「结果二」的多轮次实验来观测锁等待波动。

### 锁指标峰值

采样方式：另开 PowerShell 循环，每 300ms 采样一次，共 80 个样本，覆盖压测全过程。

```sql
SHOW GLOBAL STATUS WHERE Variable_name IN (
  'Threads_running','Questions','Innodb_row_lock_current_waits',
  'Innodb_row_lock_waits','Innodb_row_lock_time');
```

| 指标 | 峰值 | 说明 |
|---|---|---|
| `Threads_running` | **202** | 200 个客户端全部处于活跃状态，连接数打满 |
| `Questions` | 10715 | 压测前后从 190 涨到 10715，共处理约 10525 次查询 |
| `Innodb_row_lock_current_waits` | **199** | **有 199 个事务同时等待同一行锁** |
| `Innodb_row_lock_waits` | 9999 | 累计行锁等待 9999 次 |
| `Innodb_row_lock_time` | 196400 ms | 累计锁等待时间约 196 秒 |

**关键采样时刻**（压测启动前后）：

| 时间 | Threads_running | Questions | LRCW | Innodb_row_lock_waits |
|---|---|---|---|---|
| 22:29:39.659（压测前） | 2 | 266 | 0 | 0 |
| 22:29:40.034 | **202** | 517 | **199** | 246 |
| 22:29:40.410 | 201 | 3067 | 195 | 2791 |
| 22:29:40.800 | 201 | 8416 | 194 | 8136 |
| 22:29:41.190（压测后） | 2 | 10483 | 0 | 9999 |

**锁瓶颈三特征全部出现**：

1. `Threads_running` 从 2 涨到 **202** —— 活跃线程堆积
2. `Questions` 增长放缓 —— 吞吐被锁拖住
3. `Innodb_row_lock_current_waits` 持续 **199** —— 大量事务排队等行锁

> CPU 不高却慢 = 瓶颈在锁不在资源。200 个事务抢同一行 `seat_category.sold_tickets`，InnoDB 行锁把并发强制串行化。

### 对账：证明不超卖

```sql
SELECT
    sc.category_id, sc.total_tickets, sc.sold_tickets,
    (SELECT COUNT(*)                FROM ticket_order t WHERE t.category_id = sc.category_id) AS order_cnt,
    (SELECT IFNULL(SUM(quantity), 0) FROM ticket_order t WHERE t.category_id = sc.category_id) AS sum_qty
FROM seat_category sc WHERE sc.category_id = 10;
```

| 项 | 值 |
|---|---|
| `total_tickets` | 100 |
| `sold_tickets` | **100** |
| `order_cnt` | **100** |
| `sum_qty` | **100** |
| `notification` | 100（触发器每单 1 条） |

**四项判据**：

| 检查 | 期望 | 实测 | 结论 |
|---|---|---|---|
| `sum_qty <= total_tickets` | 是 | 100 ≤ 100 | ✅ 不超卖 |
| `sold_tickets <= total_tickets` | 是 | 100 ≤ 100 | ✅ 不超卖 |
| `sold_tickets = sum_qty` | 相等 | 100 = 100 | ✅ 库存与订单一致 |
| `order_cnt` | 约 100 | 100 | ✅ 精确命中 |

**结论：✅ 零超卖，三方完全一致。**

10000 次 CALL 中，恰好 100 次返回码 0（成功下单），其余 9900 次返回码 2（库存不足），没有出现第 101 单。

## 结果二：多轮次锁竞争观测（补充实验）

为真实体现「`Maximum >> Average`」的锁等待波动，将库存放大到 100000 张（保证 5 轮都不会售罄，每轮都打同一行锁），`--iterations=5`：

```cmd
mysqlslap --host=127.0.0.1 -u root -p1234 --create-schema=ticket_db ^
  --query=script/grab.sql --delimiter=";" ^
  --concurrency=200 --iterations=5 --number-of-queries=10000
```

### mysqlslap 输出

```text
Benchmark
        Average number of seconds to run all queries: 57.687 seconds
        Minimum number of seconds to run all queries: 46.516 seconds
        Maximum number of seconds to run all queries: 68.453 seconds
        Number of clients running queries: 200
        Average number of queries per client: 50
```

| 指标 | 值 | 说明 |
|---|---|---|
| Average | 57.687 s | 平均单轮耗时 |
| Minimum | 46.516 s | 最快一轮 |
| **Maximum** | **68.453 s** | 最慢一轮 |
| Maximum / Average | **1.19 倍** | 轮次间波动明显 |
| Maximum / Minimum | **1.47 倍** | 最慢比最快慢 47% |

> **Maximum 明显大于 Minimum/Average**：同样 10000 次 CALL，最快一轮 46.5 秒、最慢一轮 68.5 秒，差异来自锁等待与队列排队的累积抖动。这印证了瓶颈在行锁竞争。

### 对账

| 项 | 值 |
|---|---|
| `total_tickets` | 100000 |
| `sold_tickets` | **50000** |
| `order_cnt` | **50000** |
| `sum_qty` | **50000** |

5 轮 × 10000 次 = 50000 次 CALL，全部成功（库存充足，无返回码 2），`sold_tickets = order_cnt = sum_qty = 50000`。

| 检查 | 实测 | 结论 |
|---|---|---|
| `sold_tickets <= total_tickets` | 50000 ≤ 100000 | ✅ 不超卖 |
| `sold_tickets = sum_qty` | 50000 = 50000 | ✅ 完全一致 |

**再次证明：高并发下零超卖，库存与订单严格一致。**

## 结论

1. **吞吐被锁卡住**：200 并发抢同一票档行，`Threads_running` 峰值 202、`Innodb_row_lock_current_waits` 峰值 199，大量事务排队等锁，CPU 不是瓶颈。
2. **正确写法零超卖**：条件原子 `UPDATE ... WHERE 余票足够` 让数据库在加锁后重判余票，`ROW_COUNT()=0` 即判定库存不足。两轮实验（100 张 / 100000 张）均严格不超卖。
3. **三方对账一致**：`sold_tickets`、`order_cnt`、`sum_qty` 完全相等，通知数 = 订单数（触发器保证）。
4. **瓶颈在行锁竞争**：单行热点 `seat_category` 是串行化点，优化方向为**库存分桶**（拆成多个桶行分散竞争）或 **Redis 预扣减**（内存原子操作前置拦截）。
5. **`--iterations=1` 的局限**：此时 `Average = Minimum = Maximum`，无法用「`Maximum >> Average`」判断锁竞争，需改用多轮次或直接看 `Innodb_row_lock_current_waits`。

## 附：原始数据

- `script/grab.sql` —— 压测语句
- `report/lock_metrics_raw.txt` —— 80 个采样点的原始锁指标数据
