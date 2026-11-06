-- ============================================================================
-- 抢票系统 进阶查询脚本 query_adv.sql
-- 数据库：ticket_db          前置依赖：schema.sql + seed.sql + query_basic.sql
-- 目标版本：MySQL 8.0+（依赖窗口函数 RANK/ROW_NUMBER/LAG，5.7 不支持窗口函数）
-- ----------------------------------------------------------------------------
-- 执行方式（任选其一）：
--   1) 命令行：mysql -u root -p --default-character-set=utf8mb4 < ticket_db/sql/query_adv.sql
--   2) mysql> 中：SOURCE ticket_db/sql/query_adv.sql;
--
-- 文件结构：
--   进阶①  全局热销票档 Top-3（跨场次比销量，RANK）
--   进阶②  每场次票档 Top-2（RANK + PARTITION BY event_id）
--   进阶③  用户购票汇总（按 user_name 分组：订单笔数 + 实际购票张数）
--   进阶④  月度订单趋势（订单量 vs 成交量，DATE_FORMAT 按月）
--   进阶⑤  日环比成交量（LAG 窗口函数 + 按场次分区）
--   进阶⑥  EXPLAIN 索引验证：user_id=123 走 idx_order_user
--   进阶⑦  EXPLAIN 索引验证：status=1 全表扫描，临时加 idx_order_status 后走 ref（演示后 DROP）
--
-- 口径约定（与 query_basic.sql 完全一致）：
--   · 订单状态 ticket_order.status：1=待支付 2=已支付 3=已取消 4=已超时
--   · "成交量/销量" 一律指 status = 2（已支付）订单的 quantity 之和；
--   · "订单量/笔数" 指全部状态订单数量。
--   · ticket_order.event_id 为冗余列，指向票档所属场次，必须与 category_id 同场
--     （由 seed.sql / 触发器保证，这里是进阶统计，直接引用即可）。
--   · 本文件只做只读查询与临时索引演示，不修改任何业务数据
--     （进阶⑦ 临时加/删的索引会随会话与演示结束而清理，不改变表结构）。
-- ============================================================================

USE ticket_db;

SET NAMES utf8mb4;


-- ============================================================================
-- 进阶① 全局热销票档 Top-3（跨场次）
-- ----------------------------------------------------------------------------
-- 业务含义：整个平台卖得最好的三个票档，为加场/补库存/营销导流提供依据。
-- 统计口径：sold 取已支付（status=2）订单张数之和。
-- 实现：内层用 RANK() OVER (ORDER BY sold DESC) 对票档全局排名，
--      外层包一层后 WHERE rk <= 3 筛出前三。
--      RANK 允许并列：若并列会跳过后续名次（1,1,3），适合"Top-3 名额"语义。
-- ============================================================================
SELECT event_name, category_name, price, total_tickets, sold, rk AS global_rank
FROM (
    SELECT
        e.event_name,
        sc.category_id,
        sc.category_name,
        sc.price,
        sc.total_tickets,
        SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) AS sold,
        RANK() OVER (ORDER BY SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) DESC) AS rk
    FROM seat_category sc
    INNER JOIN `event` e  ON e.event_id     = sc.event_id
    INNER JOIN ticket_order o ON o.category_id = sc.category_id
    GROUP BY e.event_name, sc.category_id, sc.category_name, sc.price, sc.total_tickets
) t
WHERE rk <= 3
ORDER BY global_rank ASC, price ASC;


-- ============================================================================
-- 进阶② 每场次票档 Top-2
-- ----------------------------------------------------------------------------
-- 业务含义：每一场演出里卖得最好的两个票档，便于不同场次横向对比与定价复盘。
-- 实现：ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY sold DESC, category_id)
--      ——在同一场次内按销量降序编号；销量相同按 category_id 保证稳定排序。
--      外层 WHERE rnk <= 2 取每场前两名。用 ROW_NUMBER 每场恰好各两条（不并列）。
-- 关联：sc → o 聚合出每票档销量，再按场次分区取 Top-2。
-- ============================================================================
SELECT event_id, event_name, category_name, price, sold, rnk AS event_top_n
FROM (
    SELECT
        sc.event_id,
        e.event_name,
        sc.category_id,
        sc.category_name,
        sc.price,
        SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) AS sold,
        ROW_NUMBER() OVER (
            PARTITION BY sc.event_id
            ORDER BY SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) DESC, sc.category_id
        ) AS rnk
    FROM seat_category sc
    INNER JOIN `event` e  ON e.event_id     = sc.event_id
    INNER JOIN ticket_order o ON o.category_id = sc.category_id
    GROUP BY sc.event_id, e.event_name, sc.category_id, sc.category_name, sc.price
) t
WHERE rnk <= 2
ORDER BY event_id ASC, rnk ASC;


-- ============================================================================
-- 进阶③ 用户购票汇总
-- ----------------------------------------------------------------------------
-- 业务含义：每个用户累计下过多少笔订单、实际买过多少张票，识别活跃用户。
-- 统计口径：
--   · order_cnt = 全部状态订单笔数（COUNT(*)）
--   · bought    = 仅已支付（status=2）订单的 quantity 之和（实际购票张数）
-- 按 user_name 分组而非 user_id：演示"业务维度"聚合；为消除重名歧义按主键兜底。
-- ============================================================================
SELECT
    u.user_name,
    u.user_id,
    COUNT(o.order_id)                                        AS order_cnt,
    SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) AS bought_qty
FROM `user` u
LEFT JOIN ticket_order o ON o.user_id = u.user_id
GROUP BY u.user_id, u.user_name
ORDER BY bought_qty DESC, order_cnt DESC
LIMIT 20;              -- 只展示前 20 位最活跃用户，避免 1000 行刷屏


-- ============================================================================
-- 进阶④ 月度订单趋势
-- ----------------------------------------------------------------------------
-- 业务含义：看订单量（下单热度）与成交量（真实售出）随月份的变化，洞察销售节奏。
-- 统计口径：
--   · month        = DATE_FORMAT(order_time, '%Y-%m')
--   · order_cnt    = 当月全部状态订单笔数
--   · sold_cnt     = 当月已支付（status=2）订单笔数
--   · sold_qty     = 当月已支付订单 quantity 之和（成交量）
-- 用 CASE 条件聚合而非 WHERE：WHERE 会把 order_cnt 也过滤成只含已支付，口径不符。
-- ============================================================================
SELECT
    DATE_FORMAT(o.order_time, '%Y-%m') AS month,
    COUNT(*)                                   AS order_cnt,   -- 当月订单量（全部状态）
    SUM(CASE WHEN o.`status` = 2 THEN 1 ELSE 0 END)     AS sold_cnt,  -- 当月成交笔数
    SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) AS sold_qty  -- 当月成交量（张）
FROM ticket_order o
GROUP BY DATE_FORMAT(o.order_time, '%Y-%m')
ORDER BY month ASC;


-- ============================================================================
-- 进阶⑤ 日环比（近 30 天成交量，按场次分区）
-- ----------------------------------------------------------------------------
-- 业务含义：观察票档销量随日期的波动，识别放票/开售带来的单日冲高。
-- 实现：LAG(COUNT(*)) OVER (PARTITION BY event_id ORDER BY DATE(order_time))
--      ——取同一场次"前一天"的订单量（成交量可用同法换成 status=2 统计）。
--      ticket_order 已有冗余列 event_id，直接 PARTITION BY o.event_id 即可，
--      无需回表反查场次。为控制输出行数，仅展示累计成交量最高的场次、最近若干天。
-- ============================================================================
WITH event_daily AS (
    SELECT
        o.event_id,
        DATE(o.order_time) AS d,
        COUNT(*)           AS day_orders            -- 当日订单量（全状态）
    FROM ticket_order o
    GROUP BY o.event_id, DATE(o.order_time)
)
SELECT
    event_id,
    d,
    day_orders,
    LAG(day_orders) OVER (PARTITION BY event_id ORDER BY d) AS prev_day_orders,
    day_orders - LAG(day_orders) OVER (PARTITION BY event_id ORDER BY d) AS day_diff
FROM event_daily
WHERE d >= (SELECT MAX(DATE(order_time)) FROM ticket_order) - INTERVAL 30 DAY
ORDER BY event_id ASC, d ASC;


-- ============================================================================
-- 进阶⑥ EXPLAIN 验证一：WHERE user_id = 123 应走 idx_order_user
-- ----------------------------------------------------------------------------
-- 目的：验证复合索引 idx_order_user(user_id, status) 的最左前缀。
-- 观察点：type = ref，key = idx_order_user，rows 明显小于总数（5000）。
-- 注意：EXPLAIN 不实际执行查询，只输出访问计划。
-- ============================================================================
EXPLAIN SELECT * FROM ticket_order WHERE user_id = 123;


-- ============================================================================
-- 进阶⑦ EXPLAIN 验证二：WHERE status = 1
-- ----------------------------------------------------------------------------
-- 第一次：只按 status 过滤。复合索引 idx_order_user(user_id, status) 以 user_id 为最左列，
--         单独按 status 过滤时最左前缀失效，访问计划应为 type = ALL（全表扫描）。
-- 解决方案：临时创建单列索引 idx_order_status(status)，再次 EXPLAIN 应看到 type = ref。
-- 演示结束后 DROP INDEX 清理临时索引，保持业务表结构不变。
-- ============================================================================
EXPLAIN SELECT * FROM ticket_order WHERE `status` = 1;

-- 临时补单列索引，验证最左前缀失效的场景
CREATE INDEX idx_order_status ON ticket_order (`status`);
-- 加索引后再看访问计划：应 type = ref，key = idx_order_status
EXPLAIN SELECT * FROM ticket_order WHERE `status` = 1;

-- 演示结束，清理临时索引，还原本表结构
DROP INDEX idx_order_status ON ticket_order;