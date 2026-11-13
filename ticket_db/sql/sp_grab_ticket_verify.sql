-- ============================================================================
-- sp_grab_ticket 验证脚本（覆盖返回码 0 / 1 / 2 / 3）
-- 数据库：ticket_db            前置依赖：sp_grab_ticket.sql 已执行
-- ----------------------------------------------------------------------------
-- 本脚本只做验证，跑完会把自己产生的测试数据清理干净，不污染 M3 造数基线：
--   基线（seed.sql 造数后）：ticket_order = 5000、notification = 5000、
--                            SUM(seat_category.sold_tickets) = 5148
--
-- 执行方式：
--   mysql -u root -p --default-character-set=utf8mb4 ticket_db < ticket_db/sql/sp_grab_ticket_verify.sql
-- ============================================================================

USE ticket_db;

SET NAMES utf8mb4;

-- ----------------------------------------------------------------------------
-- 0. 记录基线（用于最后断言 + 精确定位测试数据）
-- ----------------------------------------------------------------------------
SET @base_orders   = (SELECT COUNT(*) FROM ticket_order);
SET @base_notis    = (SELECT COUNT(*) FROM notification);
SET @base_sold_sum = (SELECT SUM(sold_tickets) FROM seat_category);
SET @base_max_oid  = (SELECT IFNULL(MAX(order_id), 0) FROM ticket_order);

-- 选一个余票充足的票档做测试目标（category_id = 1，event_id = 1）
SET @tc_cat = 1;
SET @tc_evt = (SELECT event_id FROM seat_category WHERE category_id = @tc_cat);
SET @tc_usr = 1;

SELECT '=== 基线 ===' AS step;
SELECT @base_orders AS orders, @base_notis AS notis,
       @base_sold_sum AS sold_sum, @base_max_oid AS max_order_id;

SELECT category_id, event_id, total_tickets, sold_tickets,
       total_tickets - sold_tickets AS remain
  FROM seat_category WHERE category_id = @tc_cat;

-- ----------------------------------------------------------------------------
-- 用例 1：参数非法（quantity = 0）→ 期望 1
-- ----------------------------------------------------------------------------
CALL sp_grab_ticket(@tc_usr, @tc_evt, @tc_cat, 0, @rc1);
SELECT @rc1 AS `rc1_quantity0_expect_1`;

-- ----------------------------------------------------------------------------
-- 用例 2：参数非法（user_id = NULL）→ 期望 1
-- ----------------------------------------------------------------------------
CALL sp_grab_ticket(NULL, @tc_evt, @tc_cat, 1, @rc2);
SELECT @rc2 AS `rc2_nulluser_expect_1`;

-- ----------------------------------------------------------------------------
-- 用例 3：库存不足（请求 999999 张）→ 期望 2
-- ----------------------------------------------------------------------------
CALL sp_grab_ticket(@tc_usr, @tc_evt, @tc_cat, 999999, @rc3);
SELECT @rc3 AS `rc3_nostock_expect_2`;

-- 断言：库存不足时不能扣库存
SELECT '--- 库存不足后 remain 应不变 ---' AS assertion;
SELECT total_tickets, sold_tickets, total_tickets - sold_tickets AS remain
  FROM seat_category WHERE category_id = @tc_cat;

-- ----------------------------------------------------------------------------
-- 用例 4：正常抢票（买 2 张）→ 期望 0
-- ----------------------------------------------------------------------------
CALL sp_grab_ticket(@tc_usr, @tc_evt, @tc_cat, 2, @rc4);
SELECT @rc4 AS `rc4_success_expect_0`;

-- 断言：库存 -2、订单 +1、通知 +1
SELECT '--- 成功抢票后 remain 应减少 2 ---' AS assertion;
SELECT total_tickets, sold_tickets, total_tickets - sold_tickets AS remain
  FROM seat_category WHERE category_id = @tc_cat;

SELECT '--- 新订单 ---' AS assertion;
SELECT order_id, user_id, event_id, category_id, `status`, quantity
  FROM ticket_order WHERE order_id > @base_max_oid ORDER BY order_id;

SELECT '--- 触发器生成的通知 ---' AS assertion;
SELECT notify_id, order_id, user_id, content
  FROM notification WHERE order_id > @base_max_oid ORDER BY notify_id;

-- ----------------------------------------------------------------------------
-- 用例 5：系统异常 → 期望 3，且库存必须回滚
--   构造：传不存在的 user_id（99999999），库存已扣但插入订单触发外键异常，
--         EXIT HANDLER 回滚整个事务并把返回码置 3。
-- ----------------------------------------------------------------------------
CALL sp_grab_ticket(99999999, @tc_evt, @tc_cat, 1, @rc5);
SELECT @rc5 AS `rc5_syserror_expect_3`;

SELECT '--- 系统异常后 remain 应回到用例4之后的值（库存未被吃掉）---' AS assertion;
SELECT total_tickets, sold_tickets, total_tickets - sold_tickets AS remain
  FROM seat_category WHERE category_id = @tc_cat;

-- ----------------------------------------------------------------------------
-- 6. 清理：只删本次用例 4 产生的订单（order_id > @base_max_oid），并回滚库存
-- ----------------------------------------------------------------------------
DELETE FROM ticket_order WHERE order_id > @base_max_oid;

-- notification 由 fk_noti_order ON DELETE CASCADE 自动清理；
-- 这里再兜底删一次，防止外键行为被改动。
DELETE FROM notification WHERE order_id > @base_max_oid;

UPDATE seat_category
   SET sold_tickets = sold_tickets - 2
 WHERE category_id = @tc_cat
   AND EXISTS (SELECT 1 FROM (SELECT 1) t WHERE @rc4 = 0);

-- ----------------------------------------------------------------------------
-- 7. 最终断言：三项指标必须回到基线
-- ----------------------------------------------------------------------------
SELECT '=== 清理后应与基线完全一致 ===' AS step;
SELECT
    @base_orders   AS base_orders,   COUNT(*)                    AS now_orders,
    @base_notis    AS base_notis,    (SELECT COUNT(*) FROM notification) AS now_notis,
    @base_sold_sum AS base_sold_sum, (SELECT SUM(sold_tickets) FROM seat_category) AS now_sold_sum
  FROM ticket_order;

SELECT '=== 返回码汇总（期望 1,1,2,0,3）===' AS step;
SELECT @rc1 AS rc1, @rc2 AS rc2, @rc3 AS rc3, @rc4 AS rc4, @rc5 AS rc5;
