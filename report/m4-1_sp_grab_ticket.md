# M4-1 存储过程 sp_grab_ticket 验证记录

## 环境

| 项 | 值 |
|---|---|
| MySQL | 8.4.11 (MySQL Community Server - GPL) |
| 操作系统 | Windows |
| 数据库 | `ticket_db` |
| 隔离级别 | `REPEATABLE-READ`（默认） |
| 基线数据 | `user=1000`、`event=5`、`seat_category=20`、`ticket_order=5000`、`notification=5000` |

## 脚本清单

| 文件 | 作用 |
|---|---|
| `ticket_db/sql/sp_grab_ticket.sql` | 建存储过程（含 `DROP PROCEDURE IF EXISTS`，可重复执行） |
| `ticket_db/sql/sp_grab_ticket_verify.sql` | 5 个验证用例，覆盖返回码 0/1/2/3，跑完自动清理 |

## 存储过程设计

核心逻辑：**事务内「条件原子 UPDATE 扣库存 + 插入订单」**，用 `WHERE` 让数据库重判余票，避免「先查再扣」的丢失修改问题。

```sql
START TRANSACTION;

UPDATE seat_category
   SET sold_tickets = sold_tickets + p_quantity
 WHERE category_id = p_category_id
   AND event_id    = p_event_id
   AND total_tickets - sold_tickets >= p_quantity;

IF ROW_COUNT() = 0 THEN ROLLBACK; SET p_result_code = 2; LEAVE sp_main; END IF;

INSERT INTO ticket_order (user_id, event_id, category_id, order_time, `status`, quantity)
VALUES (p_user_id, p_event_id, p_category_id, NOW(3), 2, p_quantity);

COMMIT;
SET p_result_code = 0;
```

异常处理：`DECLARE EXIT HANDLER FOR SQLEXCEPTION` → `ROLLBACK` + 返回码 3。

## 返回码定义

| 返回码 | 含义 |
|---|---|
| 0 | 抢票成功 |
| 1 | 参数非法（任一项为 NULL，或 `quantity = 0`） |
| 2 | 库存不足（含票档不存在、场次与票档不匹配） |
| 3 | 系统异常（SQL 异常，事务已回滚） |

## 验证结果

执行 `sp_grab_ticket_verify.sql`，5 个用例全部符合预期：

| # | 用例 | 调用参数 | 期望 | 实测 | 结论 |
|---|---|---|---|---|---|
| 1 | 数量为 0 | `(1, 1, 1, 0)` | 1 | **1** | ✅ |
| 2 | 用户为 NULL | `(NULL, 1, 1, 1)` | 1 | **1** | ✅ |
| 3 | 库存不足 | `(1, 1, 1, 999999)` | 2 | **2** | ✅ |
| 4 | 正常抢票 | `(1, 1, 1, 2)` | 0 | **0** | ✅ |
| 5 | 系统异常（user_id 不存在触发外键） | `(99999999, 1, 1, 1)` | 3 | **3** | ✅ |

**返回码汇总：`1, 1, 2, 0, 3` —— 与期望完全一致。**

### 原子性验证（返回码 3 时库存未变）

用例 5 传入了不存在的 `user_id`，库存已在事务中扣减，但插入订单时触发 `fk_order_user` 外键异常：

| 阶段 | `sold_tickets` | 说明 |
|---|---|---|
| 用例 4 成功后 | 250 | 正常扣减 2 张 |
| 用例 5 异常后 | **250** | ✅ 事务已回滚，库存未被吃掉 |

### 成功路径的连带效果

用例 4（买 2 张）实测产生：

- `seat_category.sold_tickets`：248 → 250（+2）
- `ticket_order`：新增 1 单（`order_id=5001`，`user_id=1`、`event_id=1`、`category_id=1`、`status=2`、`quantity=2`）
- `notification`：触发器 `trg_order_notify` 自动生成 1 条，内容为「订单 5001 已提交：购票 2 张，当前状态 已支付。」

### 可重复执行验证

连续执行 `sp_grab_ticket.sql` 两次，第二次无 `ERROR 1304`（`PROCEDURE already exists`），确认 `DROP PROCEDURE IF EXISTS` 生效。

### 数据基线未被污染

验证脚本结束时会精确删除测试订单并回滚库存，实测清理后：

```
ticket_order = 5000、notification = 5000、SUM(sold_tickets) = 5148
```

与验证前基线完全一致；20 个票档逐行比对备份，0 处差异。

## 已修复的原始缺陷

原草稿（40 行）存在以下问题，均已修正：

| # | 原缺陷 | 修复 |
|---|---|---|
| 1 | 缺 `DROP PROCEDURE IF EXISTS`，重跑报 `ERROR 1304` | 已添加 |
| 2 | 参数用 `INT`，与主键 `BIGINT UNSIGNED` 不匹配 | 改为 `BIGINT UNSIGNED` / `INT UNSIGNED` |
| 3 | `INSERT` 漏写 `event_id`（NOT NULL 外键，必报 `ERROR 1364`） | 已补上 |
| 4 | 残留未使用变量 `v_order_id` | 已删除 |
| 5 | 验证段硬编码不存在的 `event_id=69`、`category_id=362` | 移至独立验证脚本，改用真实 ID |
| 6 | 无 `IF ... THEN` 包裹的参数判断，`LEAVE` 前缺 `END IF` 结构 | 已按标准语法重写 |

## 结论

- 存储过程已建立并可从 `ticket_db` 正常调用。
- 四个返回码 0/1/2/3 全部复现，与设计一致。
- 返回码 3 时事务完整回滚，库存未被吃掉，原子性成立。
- 脚本可重复执行，无硬编码无效 ID。
