# 抢票系统 ticket_db（LAB1031）

MySQL 8.0+ 实现的演唱会抢票系统数据库实验项目，覆盖建库建表、造数、业务查询、存储过程与并发压测。

## 目录结构

```text
lab1031/
├── README.md                        本文件
├── docs/                            文档与设计图
│   └── ER图.png                     数据库 ER 图
├── sql/                             SQL 脚本（按执行顺序）
│   ├── schema.sql                   建库 + 建 5 张表（整库重建）
│   ├── seed.sql                     造数（用户/场次/票档/订单/触发器/存储过程）
│   ├── query_basic.sql              视图 v_event_remain + 6 条基础查询
│   ├── query_adv.sql                5 条进阶查询 + EXPLAIN 索引验证
│   ├── sp_grab_ticket.sql           抢票存储过程（事务内扣库存 + 下单，防超卖）
│   └── sp_grab_ticket_verify.sql    返回码 0/1/2/3 验证用例（跑完自动清理）
├── script/                          压测与运维脚本
│   ├── grab.sql                     mysqlslap 压测语句（单行）
│   ├── run_stress_test.ps1          一键压测：造库存 → mysqlslap → 对账
│   └── sample_lock_metrics.ps1      锁指标采样（判断瓶颈是否在锁）
└── report/                          实验报告
    ├── m4-1_sp_grab_ticket.md       存储过程设计 + 四种返回码验证记录
    ├── m4-2_stress_test.md          200 并发压测记录 + 对账结论
    └── lock_metrics_raw.txt         压测锁指标原始采样数据
```

## 数据库设计

| 表 | 说明 | 行数 |
|---|---|---|
| `user` | 用户表，手机号唯一 | 1000 |
| `event` | 场次表 | 5 |
| `seat_category` | 票档表，含总票数与已售票数 | 20 |
| `ticket_order` | 订单表，状态 1=待支付 2=已支付 3=已取消 4=已超时 | 5000 |
| `notification` | 通知表，由订单触发器自动生成 | 5000 |

外键 6 条，视图 1 个（`v_event_remain`），触发器 1 个（`trg_order_notify`），存储过程 2 个。

## 执行顺序

```sql
SOURCE sql/schema.sql;                -- 建库建表（会 DROP DATABASE，慎用）
SOURCE sql/seed.sql;                  -- 造数（可重复执行，行数固定 1000/5/20/5000/5000）
SOURCE sql/query_basic.sql;           -- 视图 + 基础查询
SOURCE sql/query_adv.sql;             -- 进阶查询 + 索引验证
SOURCE sql/sp_grab_ticket.sql;        -- 抢票存储过程（含 DROP IF EXISTS，可重复执行）
SOURCE sql/sp_grab_ticket_verify.sql; -- 验证返回码，跑完自动清理测试数据
```

命令行执行（含 `DELIMITER` 的脚本必须用输入重定向）：

```bash
mysql -u root -p --default-character-set=utf8mb4 ticket_db < sql/sp_grab_ticket.sql
```

## sp_grab_ticket 存储过程

事务内「条件原子 UPDATE 扣库存 + 插入订单」，用 `WHERE` 让数据库重判余票，避免「先查再扣」的丢失修改问题。

| 返回码 | 含义 |
|---|---|
| 0 | 抢票成功（库存已扣、订单已生成） |
| 1 | 参数非法（任一项为 NULL，或数量为 0） |
| 2 | 库存不足（含票档不存在、场次与票档不匹配） |
| 3 | 系统异常（SQL 异常，事务已回滚） |

调用示例：

```sql
SET @rc = NULL;
CALL sp_grab_ticket(1, 1, 1, 2, @rc);
SELECT @rc;
```

## 压测

```powershell
# 一键执行：调连接数 → 造 100 张热点库存 → mysqlslap 200 并发 → 对账
.\script\run_stress_test.ps1

# 压测完成后恢复 5000 单基线
mysql -u root -p --default-character-set=utf8mb4 ticket_db < sql/seed.sql
```

**实测结论**：200 并发抢 100 张，`Threads_running` 峰值 202、`Innodb_row_lock_current_waits` 峰值 199，吞吐被行锁卡住；对账 `sold_tickets = order_cnt = sum_qty = 100`，**零超卖**。详见 [report/m4-2_stress_test.md](report/m4-2_stress_test.md)。

## 注意事项

- 所有 SQL 文件均为 **UTF-8** 编码，执行时请带 `--default-character-set=utf8mb4`。
- 命令行执行含 `DELIMITER` 的脚本，请用输入重定向（`< 文件`），不要用 `-e "SOURCE ..."`。
- `sp_grab_ticket_verify.sql` 会产生临时订单，但结束时会精确删除并回滚库存，不污染基线。
- `run_stress_test.ps1` 会清空 `ticket_order` / `notification`，压测后需重跑 `seed.sql` 恢复基线。
