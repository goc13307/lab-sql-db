# 抢票系统 ticket_db · 数据库脚本集（LAB1031）

一个基于 MySQL 8.0+ 的演出票务数据库练习库，包含建库建表、造数、基础查询与进阶查询脚本。

- 数据库名：`ticket_db`
- 目标版本：MySQL 8.0+（`query_adv.sql` 依赖窗口函数，需 8.0；其余脚本 5.7 亦可运行）
- 远程仓库：`https://github.com/goc13307/lab-sql-db.git`，分支 `main`

---

## 1. 目录结构

```text
ticket_db/
└── sql/
    ├── schema.sql         建库 + 建 5 张表（整库重建脚本）
    ├── seed.sql           造数（用户/场次/票档/订单/触发器/存储过程）
    ├── query_basic.sql    视图 v_event_remain + 6 条基础查询
    └── query_adv.sql      5 条进阶查询 + EXPLAIN 索引验证
```

## 2. 运行顺序

**必须按以下顺序执行**（顺序即外键依赖顺序）：

1. `ticket_db/sql/schema.sql` —— 建库 + 建 5 张表
2. `ticket_db/sql/seed.sql` —— 造数 + 触发器/存储过程
3. `ticket_db/sql/query_basic.sql` —— 创建视图 + 基础查询
4. `ticket_db/sql/query_adv.sql` —— 进阶查询 + EXPLAIN 验证

命令行示例（PowerShell 不支持 `<` 重定向，用 `cmd /c`）：

```powershell
cmd /c "mysql -u root -p --default-character-set=utf8mb4 < ticket_db/sql/schema.sql"
cmd /c "mysql -u root -p --default-character-set=utf8mb4 < ticket_db/sql/seed.sql"
cmd /c "mysql -u root -p --default-character-set=utf8mb4 < ticket_db/sql/query_basic.sql"
cmd /c "mysql -u root -p --default-character-set=utf8mb4 < ticket_db/sql/query_adv.sql"
```

## 3. ⚠ 破坏性脚本警告

`schema.sql` 第 45 行执行 **`DROP DATABASE IF EXISTS ticket_db`**，会删除 `ticket_db` 中的
全部数据、视图、触发器与存储过程后整库重建。

**重跑任何一步前，务必确认已将数据库备份**（见下），且没有其它客户端（如 HeidiSQL、应用）占用会话。

```powershell
mysqldump -u root -p --routines --triggers --databases ticket_db > ticket_db_before_schema.sql
```

> 备份文件 `ticket_db_before_schema.sql` 仅作本机回退用，**不要纳入 Git**。

## 4. 造数规模（seed.sql 口径）

| 表               | 行数   | 说明                                            |
| ---------------- | ------ | ----------------------------------------------- |
| `user`           | 1000   | 用户，`phone` 唯一                              |
| `event`          |    5   | 5 场真实演唱会场次                              |
| `seat_category`  |   20   | 每场 4 个票档（5 × 4）                          |
| `ticket_order`   | 5000   | 订单，`event_id` 取自所属票档，场次-票档一致     |
| `notification`   | 5000   | 由订单触发器 `trg_order_notify` 自动生成（每单一通知） |

`seed.sql` 可安全重跑：开头按外键反序清空 5 表并复位自增，最终行数固定为 `1000 / 5 / 20 / 5000 / 5000`。

## 5. 订单状态口径（贯穿所有脚本）

- `ticket_order.status`：`1=待支付 2=已支付 3=已取消 4=已超时`
- `event.status`：`0=待开售 1=预售中 2=已开售 3=已结束 4=已取消`
- 库存冗余：`seat_category.sold_tickets` 已支付订单占用，`余票 = total_tickets - sold_tickets`

## 6. M3 验收清单（已核对）

- ✅ `schema.sql` 替换旧版 `ticket_db.sql`，仓库仅保留一份建库脚本
- ✅ `ticket_order` 含 `event_id`，外键总数 = **6**
- ✅ 5 表行数 = `1000 / 5 / 20 / 5000 / 5000`
- ✅ `ticket_order.event_id` 无 NULL，且与票档所属场次无不一致
- ✅ `seed.sql` 二次执行不报错、行数不漂移、`phone` 无重复、通知归属一致
- ✅ 视图 `v_event_remain` 存在，余票查询有结果
- ✅ 查询条数：`query_basic.sql` 6 条 + `query_adv.sql` 5 条 = **11** ≥ 10
- ✅ `EXPLAIN` 验证已记录（`idx_order_user` → `ref`；`status=1` → `ALL`；临时 `idx_order_status` → `ref`）
- ✅ `notification` 行数 = 订单数（5000，触发器每单一通知）

## 7. 关键设计说明

- `ticket_order.event_id` 为冗余列，与 `category_id` 指向的场次必须一致；外键只能保证值存在，
  不能保证两列同场，故 `seed.sql` 第 6.3 段保留了一致性核对 SQL。
- `query_basic.sql` / `query_adv.sql` 只读，不修改业务数据；唯一写操作是 `query_adv.sql` 第 7 节
  临时创建并在演示结束后 `DROP` 的单列索引 `idx_order_status`。