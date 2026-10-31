-- ============================================================================
-- 抢票系统 造数脚本 seed.sql
-- 数据库：ticket_db            前置依赖：schema.sql（建库 + 5 张表）
-- 目标版本：MySQL 8.0+（依赖递归 CTE、窗口函数 ROW_NUMBER()、存储过程）
-- ----------------------------------------------------------------------------
-- 本脚本按外键依赖顺序一次性完成全部造数任务：
--   ┌───────────────┬────────┬─────────────────────────────────────────────────────┐
--   │ 表            │ 行数   │ 造数方法                                            │
--   ├───────────────┼────────┼─────────────────────────────────────────────────────┤
--   │ user          │ 1000   │ 递归 CTE 生成序号 1..1000 + RAND() 生成手机号/注册时间 │
--   │ event         │    5   │ 联网检索的真实演唱会（来源见第 2 段注释）             │
--   │ seat_category │   20   │ INSERT ... SELECT 笛卡尔积：5 个场次 × 每场 4 个票档  │
--   │ 触发器        │    —   │ ：订单插入后自动写 notification      │
--   │ ticket_order  │ 5000   │ 存储过程 sp_seed_ticket_orders 循环 + RAND()         │
--   │ notification  │ 5000   │ 本脚本不直接写，由订单触发器逐单生成（派生数据）       │
--   └───────────────┴────────┴─────────────────────────────────────────────────────┘
--
-- 执行方式（任选其一）：
--   1) 命令行：mysql -u root -p --default-character-set=utf8mb4 < db/seed.sql
--   2) mysql> 中：SOURCE db/seed.sql;
--
-- 可重复执行：脚本开头按外键反序 TRUNCATE 五张表并复位 AUTO_INCREMENT，
--             随后按依赖顺序重造，最终行数固定为 1000 / 5 / 20 / 5000 / 5000。
-- ============================================================================

USE ticket_db;

SET NAMES utf8mb4;


-- ============================================================================
-- 0. 清理旧造数数据
--    按外键依赖反序（先子表后父表）清空，保证脚本可重复执行；
--    TRUNCATE 需要临时关闭外键检查，同时会把 AUTO_INCREMENT 复位到 1。
-- ============================================================================
SET FOREIGN_KEY_CHECKS = 0;
TRUNCATE TABLE notification;    -- 子表：依赖 ticket_order、user
TRUNCATE TABLE ticket_order;    -- 子表：依赖 user、event、seat_category
TRUNCATE TABLE seat_category;   -- 子表：依赖 event
TRUNCATE TABLE `event`;         -- 父表
TRUNCATE TABLE `user`;          -- 父表
SET FOREIGN_KEY_CHECKS = 1;


-- ============================================================================
-- 1. 用户表 user：1000 条（递归 CTE + RAND()）
-- ----------------------------------------------------------------------------
-- ① 默认递归深度为 1000，恰好 1000 行可能触顶，先调大上限；
-- ② 递归 CTE 只负责生成序号 1..1000，随机性全部交给 RAND()；
-- ③ 手机号 = '13' + 4 位序号 + 5 位随机数，共 11 位：
--    前 4 位序号保证 1000 个号码互不相同（phone 上有 UNIQUE 约束，
--    纯 9 位随机号在 1000 行下虽大概率不冲突，但一旦冲突整条 INSERT 会失败，
--    种子脚本应当可无限次重跑，因此用序号兜底唯一性）；
-- ④ create_at 取“过去 365 天内”的随机秒数，模拟用户在一年内陆续注册。
-- ============================================================================
SET SESSION cte_max_recursion_depth = 1000000;

INSERT INTO `user` (user_name, phone, create_at)
WITH RECURSIVE seq(n) AS (
    SELECT 1                    -- 递归起点：第 1 个用户
    UNION ALL
    SELECT n + 1 FROM seq
     WHERE n < 1000             -- 递归终点：第 1000 个用户
)
SELECT
    CONCAT('user', LPAD(n, 4, '0'))                                         AS user_name,
    CONCAT('13', LPAD(n, 4, '0'), LPAD(FLOOR(RAND() * 100000), 5, '0'))     AS phone,
    DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 31536000) SECOND)               AS create_at
FROM seq;


-- ============================================================================
-- 2. 场次表 event：5 条真实演唱会数据（2026-10-31 联网检索）
-- ----------------------------------------------------------------------------
-- 数据来源：
--   1) 周杰伦 广州站：https://www.nfnews.com/content/v3aOmZwAo1.html
--   2) 周深 厦门站：http://m.toutiao.com/group/7698678002254643754/
--   3) 付豪 北京站：http://www.damai.cn/?picID=747482&pkid=3023
--   4) 伊莲·霍莱斯 成都站：http://m.toutiao.com/group/7702449082513539618/
--   5) 五月天 北京站：https://www.bin-music.com.tw/news/2403
--
-- status 取值：0=待开售 1=预售中 2=已开售 3=已结束 4=已取消
-- 按检索到的开票/演出进度赋值：广州站预售中(1)，厦门/北京/成都站在售(2)，
-- 五月天北京站已于 2026-05 结束(3)。
-- ============================================================================
INSERT INTO `event` (event_name, event_time, venue, `status`) VALUES
    ('周杰伦「嘉年华」2026 世界巡回演唱会 广州站',
     '2026-12-04 19:30:00', '广州天河体育中心体育场', 1),                    -- 预售中
    ('周深「深深的」2026 巡回演唱会 厦门站',
     '2026-11-21 19:00:00', '厦门奥林匹克体育中心白鹭体育场', 2),            -- 已开售
    ('付豪《当故事 到后来》巡回演唱会特别场 北京站',
     '2026-11-14 19:30:00', '北京 LIVERSE 音宇宙艺术中心', 2),               -- 已开售
    ('伊莲·霍莱斯《我的名字叫伊莲》2026 世界巡回演唱会 成都站',
     '2026-11-06 19:30:00', '成都城市音乐厅·歌剧厅', 2),                     -- 已开售
    ('五月天「5525+2 回到那一天」25 周年巡回演唱会 北京站',
     '2026-05-01 19:00:00', '国家体育场（鸟巢）', 3);                         -- 已结束


-- ============================================================================
-- 3. 票档表 seat_category：20 条（5 个场次 × 每场 4 个票档）
-- ----------------------------------------------------------------------------
-- 用 INSERT ... SELECT + 派生表笛卡尔积批量生成，避免手写 20 行；
-- 同一场次内票档名称唯一（uk_sc_name），价格按档位递增；
-- total_tickets 预留充足，保证 5000 笔订单（最多 4 张/单）也不会超卖；
-- sold_tickets 先置 0，待订单造完后由第 6 段按已支付订单回填。
-- ============================================================================
INSERT INTO seat_category (event_id, category_name, price, total_tickets, sold_tickets)
SELECT e.event_id,          -- 每个场次
       c.category_name,     --  × 每个票档
       c.price,
       c.total_tickets,
       0
FROM `event` e
CROSS JOIN (
              SELECT '内场 VIP' AS category_name, 1280.00 AS price, 1500 AS total_tickets
    UNION ALL SELECT '内场 A 区',                880.00,            2000
    UNION ALL SELECT '看台 B 区',                580.00,            3000
    UNION ALL SELECT '看台 C 区',                280.00,            5000
) c;


-- ============================================================================
-- 4. 订单通知触发器 trg_order_notify
-- ----------------------------------------------------------------------------
-- notification 是订单的派生数据：脚本绝不直接 INSERT notification，
-- 而是在订单写入后由触发器自动生成，保证「有订单必有通知、用户归属一致」。
-- 若后续单独下发 trg_order_notify.sql，其内容与本段等价；
-- 这里先 DROP 再 CREATE，确保重复执行时始终只有一个同名触发器（不会重复发通知）。
--
-- 状态文案用 ELT() 而不是 CASE ... END：部分图形化客户端的语句切分器会把
-- CASE 结尾的 END 误判为语句结束，导致报 "near '' at line ..." 的语法错误；
-- 订单状态恰好是连续的 1..4，ELT 可直接按序号取文案，且不含 END 关键字。
-- ============================================================================
DROP TRIGGER IF EXISTS trg_order_notify;

CREATE TRIGGER trg_order_notify
AFTER INSERT ON ticket_order
FOR EACH ROW
INSERT INTO notification (order_id, user_id, content)
VALUES (
    NEW.order_id,
    NEW.user_id,                    -- 接收人直接取订单归属用户，派生冗余不独立写入
    CONCAT('订单 ', NEW.order_id, ' 已提交：购票 ', NEW.quantity, ' 张，当前状态 ',
           ELT(NEW.`status`, '待支付', '已支付', '已取消', '已超时'), '。')
);


-- ============================================================================
-- 5. 订单表 ticket_order：5000 条（存储过程循环 + RAND()）
-- ----------------------------------------------------------------------------
-- 造数要点：
--   ① 用户、票档先缓存进临时映射表并编序号，按随机序号取值，
--      不假设自增主键连续（重复执行/手工补数后依然正确）；
--   ② event_id 必须取自所选票档的所属场次，保证订单「场次-票档」一致；
--   ③ 状态按业务真实比例加权：已支付 60%、待支付 15%、已取消 15%、已超时 10%；
--   ④ 购票数量 1~4 张加权：50% / 30% / 15% / 5%；
--   ⑤ 下单时间落在「用户注册之后、当前时刻之前」，时间逻辑自洽；
--   ⑥ 整批插入放在一个事务里，任一异常整体回滚，不留半截数据。
-- ============================================================================
DROP PROCEDURE IF EXISTS sp_seed_ticket_orders;

DELIMITER $$

CREATE PROCEDURE sp_seed_ticket_orders(IN p_total INT)
BEGIN
    -- ---- 循环与取值变量 ----
    DECLARE v_i            INT DEFAULT 0;          -- 已生成订单数
    DECLARE v_user_seq     INT;                    -- 随机用户序号
    DECLARE v_user_id      BIGINT UNSIGNED;        -- 随机用户主键
    DECLARE v_user_created DATETIME(3);            -- 该用户注册时间
    DECLARE v_cat_seq      INT;                    -- 随机票档序号
    DECLARE v_category_id  BIGINT UNSIGNED;        -- 随机票档主键
    DECLARE v_event_id     BIGINT UNSIGNED;        -- 该票档所属场次
    DECLARE v_user_cnt     INT;                    -- 用户总数
    DECLARE v_cat_cnt      INT;                    -- 票档总数
    DECLARE v_roll         DOUBLE;                 -- 概率骰子
    DECLARE v_status       TINYINT;                -- 订单状态
    DECLARE v_qty          INT UNSIGNED;           -- 购票数量
    DECLARE v_order_time   DATETIME(3);            -- 下单时间
    DECLARE v_has_event_id INT DEFAULT 0;          -- ticket_order 是否含 event_id 列（兼容两版表结构）

    -- ---- 异常处理器：任一 SQL 错误 → 回滚整批 → 原样抛出，避免留半截订单 ----
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;          -- 事务未开启时 ROLLBACK 为空操作，安全
        RESIGNAL;          -- 不吞错误，调用方能看到真实原因
    END;

    -- ---- ① 用户映射表：seq 1..N ↔ user_id ----
    DROP TEMPORARY TABLE IF EXISTS tmp_seed_user;
    CREATE TEMPORARY TABLE tmp_seed_user (
        seq       INT PRIMARY KEY,
        user_id   BIGINT UNSIGNED NOT NULL,
        create_at DATETIME(3)     NOT NULL
    );
    INSERT INTO tmp_seed_user (seq, user_id, create_at)
    SELECT ROW_NUMBER() OVER (ORDER BY user_id), user_id, create_at
      FROM `user`;

    -- ---- ② 票档映射表：seq 1..M ↔ (category_id, event_id) ----
    DROP TEMPORARY TABLE IF EXISTS tmp_seed_category;
    CREATE TEMPORARY TABLE tmp_seed_category (
        seq         INT PRIMARY KEY,
        category_id BIGINT UNSIGNED NOT NULL,
        event_id    BIGINT UNSIGNED NOT NULL
    );
    INSERT INTO tmp_seed_category (seq, category_id, event_id)
    SELECT ROW_NUMBER() OVER (ORDER BY category_id), category_id, event_id
      FROM seat_category;

    -- ---- ③ 前置造数缺失时直接报错，避免生成无归属的脏订单 ----
    SELECT COUNT(*) INTO v_user_cnt FROM tmp_seed_user;
    SELECT COUNT(*) INTO v_cat_cnt  FROM tmp_seed_category;
    IF v_user_cnt = 0 OR v_cat_cnt = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '造数失败：user 或 seat_category 为空，请先执行前置造数';
    END IF;

    -- ---- ④ 探测 ticket_order 是否含 event_id 列，兼容两版建表脚本 ----
    -- schema.sql（定稿版）的 ticket_order 有 event_id；db/ticket_db.sql（旧版）没有该列。
    -- 有列则写入场次，无列则只写票档（场次可由 category_id 外键反推）。
    SELECT COUNT(*) INTO v_has_event_id
      FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = 'ticket_db'
       AND TABLE_NAME   = 'ticket_order'
       AND COLUMN_NAME  = 'event_id';

    START TRANSACTION;

    WHILE v_i < p_total DO
        SET v_i = v_i + 1;

        -- ---- 随机用户 ----
        SET v_user_seq = 1 + FLOOR(RAND() * v_user_cnt);
        SELECT user_id, create_at
          INTO v_user_id, v_user_created
          FROM tmp_seed_user
         WHERE seq = v_user_seq;

        -- ---- 随机票档（连带所属场次，保证 event_id 与 category_id 同场）----
        SET v_cat_seq = 1 + FLOOR(RAND() * v_cat_cnt);
        SELECT category_id, event_id
          INTO v_category_id, v_event_id
          FROM tmp_seed_category
         WHERE seq = v_cat_seq;

        -- ---- 订单状态加权随机 ----
        SET v_roll = RAND();
        SET v_status = CASE
            WHEN v_roll < 0.60 THEN 2      -- 已支付 60%
            WHEN v_roll < 0.75 THEN 1      -- 待支付 15%
            WHEN v_roll < 0.90 THEN 3      -- 已取消 15%
            ELSE 4                          -- 已超时 10%
        END;

        -- ---- 购票数量加权随机 ----
        SET v_roll = RAND();
        SET v_qty = CASE
            WHEN v_roll < 0.50 THEN 1      -- 1 张 50%
            WHEN v_roll < 0.80 THEN 2      -- 2 张 30%
            WHEN v_roll < 0.95 THEN 3      -- 3 张 15%
            ELSE 4                          -- 4 张 5%
        END;

        -- ---- 下单时间：注册时间 ~ 当前时刻之间的随机秒 ----
        -- TIMESTAMPDIFF 可能为 0（刚注册），+1 保证 INTERVAL 不为 0 时也能取到区间
        SET v_order_time = DATE_ADD(
            v_user_created,
            INTERVAL FLOOR(RAND() * (TIMESTAMPDIFF(SECOND, v_user_created, NOW()) + 1)) SECOND
        );

        -- ---- 写入订单；此 INSERT 会激活 trg_order_notify 自动生成 notification ----
        -- 按表结构分支：定稿版写 event_id，旧版（db/ticket_db.sql）无该列则省略
        IF v_has_event_id > 0 THEN
            INSERT INTO ticket_order (user_id, event_id, category_id, order_time, `status`, quantity)
            VALUES (v_user_id, v_event_id, v_category_id, v_order_time, v_status, v_qty);
        ELSE
            INSERT INTO ticket_order (user_id, category_id, order_time, `status`, quantity)
            VALUES (v_user_id, v_category_id, v_order_time, v_status, v_qty);
        END IF;
    END WHILE;

    -- ---- ④ 回填已售库存：sold_tickets = 该票档已支付订单的购票张数之和 ----
    -- LEAST 封顶 total_tickets，确保永远满足 ck_sc_sold 约束（防超卖底线）
    UPDATE seat_category sc
      JOIN (
            SELECT category_id, SUM(quantity) AS sold
              FROM ticket_order
             WHERE `status` = 2                 -- 仅已支付占用库存
             GROUP BY category_id
           ) o
        ON o.category_id = sc.category_id
       SET sc.sold_tickets = LEAST(o.sold, sc.total_tickets);

    COMMIT;
END $$

DELIMITER ;

-- 执行造数：5000 笔订单（触发器同步生成 5000 条通知）
CALL sp_seed_ticket_orders(5000);


-- ============================================================================
-- 6. 造数结果核对
-- ============================================================================

-- 6.1 五张表行数期望：1000 / 5 / 20 / 5000 / 5000
SELECT `表`, 行数
FROM (
              SELECT 1 AS ord, 'user'          AS `表`, COUNT(*) AS 行数 FROM `user`
    UNION ALL SELECT 2,        'event',                  COUNT(*)         FROM `event`
    UNION ALL SELECT 3,        'seat_category',          COUNT(*)         FROM seat_category
    UNION ALL SELECT 4,        'ticket_order',           COUNT(*)         FROM ticket_order
    UNION ALL SELECT 5,        'notification',           COUNT(*)         FROM notification
) t
ORDER BY ord;

-- 6.2 通知归属核对：notification.user_id 必须等于所属订单的 user_id（期望 0）
SELECT COUNT(*) AS 通知归属不一致行数
FROM notification n
JOIN ticket_order o ON o.order_id = n.order_id
WHERE n.user_id <> o.user_id;

-- 6.3 订单「场次-票档」一致性核对（仅当 ticket_order 含 event_id 列时执行）
--     旧版 db/ticket_db.sql 的订单表没有 event_id，此时场次一致性由 category_id 外键天然保证
SET @has_event_col := (
    SELECT COUNT(*)
      FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = 'ticket_db'
       AND TABLE_NAME   = 'ticket_order'
       AND COLUMN_NAME  = 'event_id'
);
SET @check_sql := IF(
    @has_event_col > 0,
    'SELECT COUNT(*) AS 场次票档不一致行数 FROM ticket_order o JOIN seat_category sc ON sc.category_id = o.category_id WHERE o.event_id <> sc.event_id',
    'SELECT ''ticket_order 无 event_id 列（旧版表结构），跳过场次-票档核对'' AS 说明'
);
PREPARE chk_stmt FROM @check_sql;
EXECUTE chk_stmt;
DEALLOCATE PREPARE chk_stmt;

-- 6.4 场次 × 票档 × 销量概览
SELECT e.event_id, e.event_name, e.event_time, e.venue, e.`status`,
       COUNT(sc.category_id) AS 票档数,
       SUM(sc.total_tickets) AS 总票数,
       SUM(sc.sold_tickets)  AS 已售张数
FROM `event` e
LEFT JOIN seat_category sc ON sc.event_id = e.event_id
GROUP BY e.event_id, e.event_name, e.event_time, e.venue, e.`status`
ORDER BY e.event_id;
