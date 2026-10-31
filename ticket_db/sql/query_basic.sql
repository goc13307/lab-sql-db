-- ============================================================================
-- 抢票系统 基础查询脚本 query_basic.sql
-- 数据库：ticket_db          前置依赖：schema.sql（建库建表）+ seed.sql（造数）
-- 目标版本：MySQL 8.0+（本文件仅使用视图与聚合查询，MySQL 5.7 同样可执行）
-- ----------------------------------------------------------------------------
-- 执行方式（任选其一）：
--   1) 命令行：mysql -u root -p --default-character-set=utf8mb4 < db/sql/query_basic.sql
--   2) mysql> 中：SOURCE db/sql/query_basic.sql;
--
-- 文件结构：
--   0. 视图 v_event_remain   场次级余票视图（查询①直接基于它）
--   1. 查询①  余票 > 0 的场次，按余票降序
--   2. 查询②  指定用户的订单，关联场次名，按下单时间降序
--   3. 查询③  按场次汇总订单笔数与售票数，HAVING 筛选售票数 > 100
--   4. 查询④  指定场次各票档的总票数、已售票数、剩余票数，按价格排序
--   5. 说明一  WHERE 与 HAVING 的区别
--   6. 说明二  笛卡尔积风险检查
--
-- 口径约定（贯穿全文）：
--   · 场次状态 event.status：0=待开售 1=预售中 2=已开售 3=已结束 4=已取消
--   · 订单状态 ticket_order.status：1=待支付 2=已支付 3=已取消 4=已超时
--   · 库存口径：seat_category.sold_tickets 是「已支付订单占用」的派生冗余列，
--     余票 = total_tickets - sold_tickets，由 ck_sc_sold 约束保证不会为负。
--
-- 本文件只创建/替换视图并执行只读查询，不修改任何业务数据。
-- ============================================================================

USE ticket_db;

SET NAMES utf8mb4;


-- ============================================================================
-- 0. 视图 v_event_remain：场次级余票视图
-- ----------------------------------------------------------------------------
-- 业务含义：
--   抢票页面与售票监控关注的是「整个场次还剩多少票」，而不是单个票档。
--   本视图把一场演出的全部票档汇总成一行：
--     总票数   = 该场次各票档 total_tickets 之和
--     已售票数 = 该场次各票档 sold_tickets  之和（已支付订单占用库存）
--     余票     = 总票数 - 已售票数
--   同时带出场次名称、开演时间、场馆与状态，查询方无需再回表 event。
--
-- 设计说明：
--   ① 用 INNER JOIN 连 event ↔ seat_category：票档通过外键强制隶属场次，
--      不存在「无场次」的票档，因此不会漏掉有效票档。
--   ② 在视图内完成 GROUP BY 聚合，下游查询不必各自重复写聚合逻辑；
--      视图内不写 ORDER BY，排序由使用方按各自场景指定。
--   ③ 余票取冗余列 sold_tickets，而不是实时汇总 ticket_order：
--      抢票场景下本视图会被高频读取，实时汇总海量订单成本高；
--      sold_tickets 由下单扣减 / 订单回填维护（见 seed.sql 第 5 段回填）。
-- ============================================================================
CREATE OR REPLACE VIEW v_event_remain AS
SELECT
    e.event_id,
    e.event_name,
    e.event_time,
    e.venue,
    e.`status`,                                         -- 场次状态：0=待开售 … 4=已取消
    SUM(sc.total_tickets)                   AS total_tickets,   -- 场次总票数
    SUM(sc.sold_tickets)                    AS sold_tickets,    -- 场次已售票数
    SUM(sc.total_tickets - sc.sold_tickets) AS remain_tickets   -- 场次余票（≥0）
FROM `event` e
INNER JOIN seat_category sc ON sc.event_id = e.event_id
GROUP BY e.event_id, e.event_name, e.event_time, e.venue, e.`status`;


-- ============================================================================
-- 1. 查询①：余票大于 0 的场次，按余票从高到低排序
-- ----------------------------------------------------------------------------
-- 业务含义：售票监控 / 捡漏列表——列出仍然有余票的场次，余票多的排前面，
--          方便运营优先推送库存充足的场次，也方便用户判断哪里还买得到。
-- 说明：视图已按场次聚合，这里只做行级筛选（WHERE）与排序，无需再 JOIN。
--      若只想看「在售」场次，可追加 AND `status` IN (1, 2)（1=预售中 2=已开售）。
-- ============================================================================
SELECT
    event_id,
    event_name,
    event_time,
    venue,
    `status`,
    total_tickets,
    sold_tickets,
    remain_tickets
FROM v_event_remain
WHERE remain_tickets > 0             -- 行级过滤：剔除已售罄场次
ORDER BY remain_tickets DESC;        -- 余票降序：库存最多的场次排最前


-- ============================================================================
-- 2. 查询②：指定用户（user_id = 123）的订单，关联场次名，按下单时间降序
-- ----------------------------------------------------------------------------
-- 业务含义：用户「我的订单」列表——显示该用户买过哪场演出、什么票档、
--          单价与数量、订单当前状态；最近下的订单排最前。
-- 关联路径（全部显式 INNER JOIN ... ON，每一步都是 n:1，不会放大行数）：
--   ticket_order o   → user u           通过 o.user_id      关联下单人
--   ticket_order o   → seat_category sc 通过 o.category_id  关联票档名称与价格
--   seat_category sc → event e          通过 sc.event_id    关联场次名称
-- 说明：场次名经由票档反查，不依赖 ticket_order.event_id，
--      因此旧版 db/ticket_db.sql（订单表无 event_id 列）同样可执行。
-- 用法：把 123 换成实际用户编号即可；123 落在 seed.sql 生成的 1..1000 用户范围内。
-- ============================================================================
SELECT
    o.order_id,
    u.user_name,
    e.event_name,
    sc.category_name,
    sc.price,
    o.quantity,
    o.`status`,                      -- 订单状态：1=待支付 2=已支付 3=已取消 4=已超时
    o.order_time
FROM ticket_order o
INNER JOIN `user`         u  ON u.user_id     = o.user_id
INNER JOIN seat_category  sc ON sc.category_id = o.category_id
INNER JOIN `event`        e  ON e.event_id    = sc.event_id
WHERE u.user_id = 123                -- 行级过滤：只看指定用户
ORDER BY o.order_time DESC;          -- 下单时间降序：最新订单在前


-- ============================================================================
-- 3. 查询③：按场次汇总订单笔数与售票数，HAVING 筛选售票数大于 100 的场次
-- ----------------------------------------------------------------------------
-- 业务含义：场次销量排行 / 对账——每个场次累计多少笔订单、实际卖出多少张票，
--          只看售票数超过 100 的场次，过滤掉销量过小的长尾场次。
-- 统计口径：
--   订单笔数 = 该场次全部订单数（含待支付、已取消、已超时，反映下单热度）；
--   售票数   = 仅已支付（status = 2）订单的 quantity 之和，取消/超时不计销量。
--   这里用 CASE 条件聚合而不是 WHERE o.status = 2：
--   若加 WHERE 会把「订单笔数」也一并变成“已支付订单笔数”，与需求口径不符。
-- HAVING 判断的是分组后的聚合结果（SUM），无法用 WHERE 替代。
-- 关联路径（全部显式 INNER JOIN ... ON）：
--   event e → seat_category sc（1:n）→ ticket_order o（1:n）
--   每条订单只属于一个票档，所以每笔订单只会被计入一次，统计不会重复。
-- 说明：阈值 100 可按需调整；seed.sql 每场已支付销量约千张，当前数据通常会全部入选，
--      此处主要用于演示 HAVING 的组级过滤语法。
-- ============================================================================
SELECT
    e.event_id,
    e.event_name,
    COUNT(o.order_id)                                        AS 订单笔数,   -- 全部状态的订单数
    SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) AS 售票数      -- 仅已支付的数量
FROM `event` e
INNER JOIN seat_category sc ON sc.event_id   = e.event_id
INNER JOIN ticket_order  o  ON o.category_id = sc.category_id
GROUP BY e.event_id, e.event_name
HAVING SUM(CASE WHEN o.`status` = 2 THEN o.quantity ELSE 0 END) > 100   -- 组级过滤：售票数 > 100
ORDER BY 售票数 DESC;                                                    -- 销量从高到低


-- ============================================================================
-- 4. 查询④：指定场次（event_id = 1）各票档的总票数、已售票数、剩余票数，按价格排序
-- ----------------------------------------------------------------------------
-- 业务含义：票档库存明细——运营核对某个场次每个价位档卖了多少、还剩多少，
--          价格从低到高排列，便于逐档盘点与补票。
-- 关联路径：event e INNER JOIN seat_category sc ON sc.event_id = e.event_id
--   显式 JOIN 一是保证场次存在，二是把场次名带入结果，方便核对；
--   若只用 sc.event_id 过滤而不 JOIN，结果缺少场次名。
-- 余票 = total_tickets - sold_tickets：ck_sc_sold 约束保证 sold_tickets ≤ total_tickets，
--      不会出现负数（也不会发生无符号整数回绕）。
-- 用法：把 event_id = 1 换成目标场次即可（seed.sql 中 1 为周杰伦广州站）。
-- ============================================================================
SELECT
    e.event_name,
    sc.category_id,
    sc.category_name,
    sc.price,
    sc.total_tickets,
    sc.sold_tickets,
    sc.total_tickets - sc.sold_tickets AS remain_tickets   -- 该票档余票
FROM `event` e
INNER JOIN seat_category sc ON sc.event_id = e.event_id
WHERE e.event_id = 1                 -- 行级过滤：锁定指定场次
ORDER BY sc.price ASC;               -- 价格升序：从最低档到最高档逐档核对


-- ============================================================================
-- 5. 说明一：WHERE 与 HAVING 的区别
-- ----------------------------------------------------------------------------
--   ① 作用阶段不同
--      WHERE  在 GROUP BY 之前执行，逐行判断，只保留满足条件的行；
--      HAVING 在 GROUP BY 之后执行，以「组」为单位判断，只保留满足条件的组。
--      也就是说：WHERE 减少的是参与分组的数据量，HAVING 减少的是最终输出的组数。
--   ② 可用内容不同
--      WHERE 不能使用聚合函数（SUM / COUNT / AVG 等），因为此时还没有分组结果；
--      HAVING 可以使用聚合函数，也可以引用分组键。
--   ③ 性能取舍
--      凡是能在分组前判断的单行条件，都应优先写在 WHERE（先筛行，分组量更小、更快）；
--      HAVING 只用于分组前无法判断的「组级条件」，如「某场次售票数 > 100」。
--   ④ 本文件的对照
--      查询① / ② / ④ 的 WHERE 都是行级条件：余票 > 0、指定用户、指定场次；
--      查询③ 的「售票数 > 100」依赖 SUM 的结果，只能在分组后判断，因此必须用 HAVING。
--      补充：MySQL 允许 HAVING 直接引用 SELECT 中的别名（MySQL 扩展，如
--      HAVING 售票数 > 100）；标准 SQL 与其他数据库需写成完整的聚合表达式
--      HAVING SUM(CASE WHEN ... END) > 100，本文件为可读性使用了完整表达式。
--   ⑤ 常见误区
--      把聚合条件写进 WHERE（如 WHERE SUM(quantity) > 100）会直接报错；
--      反过来把行级条件写成 HAVING（如 HAVING o.status = 2）虽然在 MySQL 可能通过，
--      但语义不清晰，也失去了提前过滤带来的性能收益，不推荐。
-- ============================================================================


-- ============================================================================
-- 6. 说明二：笛卡尔积风险检查
-- ----------------------------------------------------------------------------
--   风险来源：多表查询漏写 ON 条件，或 ON 条件不足以唯一匹配，
--             结果行数会按「左表行数 × 右表行数」膨胀，聚合结果随之失真。
--   逐条检查结论：
--     视图 v_event_remain：
--       event INNER JOIN seat_category ON sc.event_id = e.event_id，
--       关联列是外键且有索引 idx_sc_event；一个场次对应多个票档，
--       属于预期的 1:n 展开，随后的 GROUP BY 按场次收敛，
--       SUM 只累加本场次自己的票档，不会重复计算。
--     查询①：基于已聚合的视图做单表查询，没有 JOIN，不存在笛卡尔积。
--     查询②：o → u（o.user_id = u.user_id）、o → sc（o.category_id = sc.category_id）、
--       sc → e（sc.event_id = e.event_id），三个关联方向都是 n:1（被关联侧主键唯一），
--       一条订单只产生一行，不会放大。
--     查询③：e → sc（1:n）→ o（1:n），而每条订单只属于一个票档，
--       所以每笔订单只被计入一次，COUNT / SUM 的统计口径正确。
--       ⚠ 潜在陷阱：若未来把订单明细再接到已聚合的视图上按 event_id 求和，
--         同一场次的余票会被订单条数重复累加（典型的「聚合表再 JOIN 明细」陷阱），
--         此时应按场次去重，或回到明细层一次性聚合。
--     查询④：e → sc 为 1:n，且 WHERE 锁定单个场次，按票档逐行输出，无重复。
--   其它注意：
--     · 所有 ON 条件都带表别名，避免同名字段（如 event_id）归属歧义；
--     · 本文件不使用 CROSS JOIN 或逗号连接；
--     · seed.sql 中的 CROSS JOIN 是造数时刻意用「场次 × 票档」批量生成票档，
--       属于有意为之，不是本查询脚本的隐患；
--     · 后续新增 JOIN 时，应确认关联列位于主键或唯一键上，或先用
--       COUNT(*) 与 COUNT(DISTINCT 主键) 对比，验证行数是否被放大。
-- ============================================================================
