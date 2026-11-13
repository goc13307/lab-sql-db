-- ============================================================================
-- 抢票系统 抢票存储过程 sp_grab_ticket
-- 数据库：ticket_db            前置依赖：schema.sql + seed.sql
-- 目标版本：MySQL 8.0+
-- ----------------------------------------------------------------------------
-- 作用：在一个事务内完成「扣库存 + 下单」，保证不超卖、失败不留脏数据。
--
-- 返回码 p_result_code：
--   0 = 抢票成功
--   1 = 参数非法（任一项为 NULL，或 quantity <= 0）
--   2 = 库存不足（含票档不存在、场次与票档不匹配、已售罄）
--   3 = 系统异常（SQL 异常，已回滚）
--
-- 执行方式（任选其一）：
--   1) 命令行：mysql -u root -p --default-character-set=utf8mb4 ticket_db < sql/sp_grab_ticket.sql
--   2) mysql> 中：SOURCE sql/sp_grab_ticket.sql;
--
-- 可重复执行：开头 DROP PROCEDURE IF EXISTS，重复执行不会报 ERROR 1304。
-- 验证用例见同目录 sp_grab_ticket_verify.sql（覆盖 0/1/2/3 四个返回码）。
-- ============================================================================

USE ticket_db;

SET NAMES utf8mb4;

DROP PROCEDURE IF EXISTS sp_grab_ticket;

DELIMITER $$

CREATE PROCEDURE sp_grab_ticket(
    IN  p_user_id     BIGINT UNSIGNED,
    IN  p_event_id    BIGINT UNSIGNED,
    IN  p_category_id BIGINT UNSIGNED,
    IN  p_quantity    INT UNSIGNED,
    OUT p_result_code INT
)
sp_main:
BEGIN
    -- 异常处理：任何 SQL 异常都回滚，并把返回码置 3
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_result_code = 3;
    END;

    -- 默认按系统异常处理，成功路径会覆盖
    SET p_result_code = 3;

    -- ---- 参数校验：任一项为 NULL 或数量为 0 视为非法 ----
    IF p_user_id IS NULL OR p_event_id IS NULL OR p_category_id IS NULL
       OR p_quantity IS NULL OR p_quantity = 0 THEN
        SET p_result_code = 1;
        LEAVE sp_main;
    END IF;

    START TRANSACTION;

    -- ---- 步骤 1：扣库存（原子条件更新，防止超卖）----
    -- WHERE 中带 total_tickets - sold_tickets >= p_quantity：
    -- 并发下由 InnoDB 行锁保证同一票档串行更新，库存不足时 ROW_COUNT() = 0。
    -- 同时校验 event_id，避免「票档与场次不匹配」的越权下单。
    UPDATE seat_category
       SET sold_tickets = sold_tickets + p_quantity
     WHERE category_id = p_category_id
       AND event_id    = p_event_id
       AND total_tickets - sold_tickets >= p_quantity;

    IF ROW_COUNT() = 0 THEN
        -- 库存不足 / 票档不存在 / 场次与票档不匹配，统一按库存不足返回
        ROLLBACK;
        SET p_result_code = 2;
        LEAVE sp_main;
    END IF;

    -- ---- 步骤 2：插入订单（status = 2 已支付）----
    -- 注意：ticket_order.event_id 是 NOT NULL 外键，必须显式写入，否则报 ERROR 1364。
    -- 订单插入后由触发器 trg_order_notify 自动写入 notification。
    INSERT INTO ticket_order (user_id, event_id, category_id, order_time, `status`, quantity)
    VALUES (p_user_id, p_event_id, p_category_id, NOW(3), 2, p_quantity);

    COMMIT;
    SET p_result_code = 0;
END sp_main$$

DELIMITER ;

-- ----------------------------------------------------------------------------
-- 调用示例
-- ----------------------------------------------------------------------------
-- SET @rc = NULL;
-- CALL sp_grab_ticket(1, 1, 1, 2, @rc);
-- SELECT @rc;   -- 0 成功 / 1 参数非法 / 2 库存不足 / 3 系统异常
