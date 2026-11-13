-- ============================================================================
-- 抢票系统 数据库脚本集
-- 数据库：ticket_db        目标版本：MySQL 8.0+
-- ----------------------------------------------------------------------------
-- 脚本清单与执行顺序（必须按此顺序，顺序即外键依赖顺序）：
--   1. schema.sql        建库 + 建 5 张表
--   2. seed.sql          造数（用户/场次/票档/订单/触发器/存储过程）
--   3. query_basic.sql   视图 + 基础查询
--   4. query_adv.sql     进阶查询
--
-- 一键执行（mysql 客户端，/ 为当前仓库目录）：
--   SOURCE sql/schema.sql;
--   SOURCE sql/seed.sql;
--   SOURCE sql/query_basic.sql;
--   SOURCE sql/query_adv.sql;
--
-- 重置方式：重跑 schema.sql 会 DROP DATABASE 重建，视图/触发器/存储过程一并消失，
--           其后 3 个执行/查询脚本需重新执行（seed.sql 负责重建触发器与过程）。
-- ============================================================================

-- ============================================================================
-- 抢票系统 数据库建库建表脚本
-- 数据库名称：ticket_db
-- 目标版本：MySQL 8.0+（MySQL 5.7 兼容说明见文件末尾）
-- 依据：项目定稿 ER 图 + 关系模式
-- 关系模式：
--   user( <u>user_id</u>, user_name, phone, create_at )
--   event( <u>event_id</u>, event_name, event_time, venue, status )
--   seat_category( <u>category_id</u>, #event_id, category_name, price,
--                  total_tickets, sold_tickets )
--   ticket_order( <u>order_id</u>, #user_id, #category_id, order_time,
--                 status, quantity )
--   notification( <u>notify_id</u>, #order_id, #user_id, content, create_at,
--                 is_read )
-- ============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ----------------------------------------------------------------------------
-- 1. 创建数据库
-- ----------------------------------------------------------------------------
DROP DATABASE IF EXISTS ticket_db;
CREATE DATABASE ticket_db
  DEFAULT CHARACTER SET utf8mb4
  DEFAULT COLLATE utf8mb4_0900_ai_ci;

USE ticket_db;

-- ----------------------------------------------------------------------------
-- 2. 用户表 user
--    联系「下单」「接收」的 1 端
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS `user`;
CREATE TABLE `user` (
  user_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '用户编号（主键）',
  user_name  VARCHAR(50)     NOT NULL                COMMENT '姓名',
  phone      VARCHAR(20)     NOT NULL                COMMENT '手机号',
  create_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '注册时间',
  PRIMARY KEY (user_id),
  UNIQUE KEY uk_user_phone (phone)	-- 手机号唯一，兼作登录标识
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '用户表';

-- ----------------------------------------------------------------------------
-- 3. 场次表 event
--    联系「划分」的 1 端
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS `event`;
CREATE TABLE `event` (
  event_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '场次编号（主键）',
  event_name  VARCHAR(200)    NOT NULL                COMMENT '场次名称',
  event_time  DATETIME(3)     NOT NULL                COMMENT '演出/赛事开演时间',
  venue       VARCHAR(200)    NOT NULL                COMMENT '场馆',
  `status`    TINYINT         NOT NULL DEFAULT 0      COMMENT '场次状态：0=待开售 1=预售中 2=已开售 3=已结束 4=已取消（取值域需业务确认）',
  PRIMARY KEY (event_id),
  KEY idx_event_status (`status`)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '场次表（一场演出/赛事对应一个场次）';

-- ----------------------------------------------------------------------------
-- 4. 票档表 seat_category
--    联系「划分」的 n 端（event_id 外键，强制参与）
--    —— 票档不能脱离场次独立存在
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS seat_category;
CREATE TABLE seat_category (
  category_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '票档编号（主键）',
  event_id       BIGINT UNSIGNED NOT NULL                COMMENT '所属场次编号（外键 → event.event_id）',
  category_name  VARCHAR(100)    NOT NULL                COMMENT '票档名称',
  price          DECIMAL(10,2)   NOT NULL                COMMENT '单价（金额一律用 DECIMAL，禁用 FLOAT）',
  total_tickets  INT UNSIGNED    NOT NULL                COMMENT '总票数',
  sold_tickets   INT UNSIGNED    NOT NULL DEFAULT 0      COMMENT '已售票数（派生冗余量，由订单汇总/实时扣减维护）',
  PRIMARY KEY (category_id),
  KEY idx_sc_event (event_id),
  UNIQUE KEY uk_sc_name (event_id, category_name),	-- 同一场次内票档名称不重复
  CONSTRAINT ck_sc_total CHECK (total_tickets > 0),
  CONSTRAINT ck_sc_price CHECK (price >= 0),
  CONSTRAINT ck_sc_sold  CHECK (sold_tickets <= total_tickets),	-- 防超卖的数据库层底线约束
  CONSTRAINT fk_sc_event FOREIGN KEY (event_id)
    REFERENCES `event` (event_id)
    ON DELETE RESTRICT          -- 禁止删除仍有票档的场次，落实"票档不可脱离场次"
    ON UPDATE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '票档表（一个场次划分为若干票档）';

-- ----------------------------------------------------------------------------
-- 5. 订单表 ticket_order
--    联系「下单」的 n 端（user_id）、联系「订购」的 n 端（category_id）
--    一张订单只订购一个票档的若干张票
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS ticket_order;
CREATE TABLE ticket_order (
  order_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单编号（主键）',
  user_id     BIGINT UNSIGNED NOT NULL                COMMENT '下单用户编号（外键 → user.user_id）',
  event_id    BIGINT UNSIGNED NOT NULL                COMMENT '所属场次编号（外键 → event.event_id）',
  category_id BIGINT UNSIGNED NOT NULL                COMMENT '所订票档编号（外键 → seat_category.category_id）',
  order_time  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '下单时间',
  `status`    TINYINT         NOT NULL DEFAULT 1      COMMENT '订单状态：1=待支付 2=已支付 3=已取消 4=已超时',
  quantity    INT UNSIGNED    NOT NULL                COMMENT '购票数量',
  PRIMARY KEY (order_id),
  KEY idx_order_user     (user_id, status)             COMMENT '我的订单列表高频查询',
  KEY idx_order_event (event_id)                 		 COMMENT '按场次统计/对账',
  KEY idx_order_category (category_id)                 COMMENT '按票档统计/对账',
  KEY idx_order_time     (order_time),
  CONSTRAINT ck_order_qty CHECK (quantity >= 1),
  CONSTRAINT fk_order_user FOREIGN KEY (user_id)
    REFERENCES user (user_id)
    ON DELETE RESTRICT          -- 有订单的用户不可删除
    ON UPDATE CASCADE,
  CONSTRAINT fk_order_event FOREIGN KEY (event_id)
    REFERENCES `event` (event_id)
    ON DELETE RESTRICT          -- 已产生订单的场次不可删除
    ON UPDATE CASCADE,
  CONSTRAINT fk_order_category FOREIGN KEY (category_id)
    REFERENCES seat_category (category_id)
    ON DELETE RESTRICT          -- 已产生订单的票档不可删除
    ON UPDATE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '订单表（用户依据票档提交订单）';

-- ----------------------------------------------------------------------------
-- 6. 通知表 notification
--    联系「触发」的 n 端（order_id）、联系「接收」的 n 端（user_id，派生冗余）
--    一张订单可触发多条通知；订单生成及状态变更时发送站内通知
-- ----------------------------------------------------------------------------
DROP TABLE IF EXISTS notification;
CREATE TABLE notification (
  notify_id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '通知编号（主键）',
  order_id   BIGINT UNSIGNED NOT NULL                COMMENT '触发通知的订单编号（外键 → ticket_order.order_id）',
  user_id    BIGINT UNSIGNED NOT NULL                COMMENT '接收用户编号（外键 → user.user_id，派生冗余，禁止独立写入，须与订单归属一致）',
  content    VARCHAR(500)    NOT NULL                COMMENT '通知内容',
  create_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '生成时间',
  is_read    TINYINT(1)      NOT NULL DEFAULT 0      COMMENT '是否已读：0=未读 1=已读',
  PRIMARY KEY (notify_id),
  KEY idx_noti_order (order_id),
  KEY idx_noti_user  (user_id, is_read, create_at)    COMMENT '站内信列表：按用户查未读',
  CONSTRAINT fk_noti_order FOREIGN KEY (order_id)
    REFERENCES ticket_order (order_id)
    ON DELETE CASCADE        -- 订单删除时其通知一并清理
    ON UPDATE CASCADE,
  CONSTRAINT fk_noti_user FOREIGN KEY (user_id)
    REFERENCES `user` (user_id)
    ON DELETE RESTRICT
    ON UPDATE CASCADE
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '通知表（订单生成及状态变更时发送的站内通知）';

SET FOREIGN_KEY_CHECKS = 1;

-- ============================================================================
-- 外键汇总（对应 ER 图联系）
--   1. seat_category.event_id     → event.event_id          划分（1:n）
--   2. ticket_order.category_id   → seat_category.category_id 票档订购（1:n）
--   3. ticket_order.event_id		  → event.event_id 场次订购（1:n）
--   4. ticket_order.user_id       → user.user_id            下单（1:n）
--   5. notification.order_id      → ticket_order.order_id   触发（1:n）
--   6. notification.user_id       → user.user_id            接收（1:n，派生冗余）
-- ============================================================================

-- ============================================================================
-- 附：上线前建议补充（当前定稿模型未包含，需评审后再决定是否 ALTER）
--   1. event.sale_start_time       开售时间 —— "开售即瞬时高并发"场景缺此项无法定时放票
--   2. ticket_order.expire_at      支付截止时间 —— 缺此项无法判定"已超时"（需求要求的状态之一）
--   3. ticket_order.paid_at / cancel_at   状态流转时间，供审计
--   4. ticket_order.unit_price / total_amount  金额快照，票档改价后历史订单可追溯
--   5. ticket_order.order_no(VARCHAR(32) UNIQUE)  对外业务单号，避免暴露自增 ID
--   6. seat_category.version       乐观锁版本号，高并发下防 sold_tickets 覆盖写
--   7. seat_category.locked_tickets  预占库存：若"支付才扣库存"，须新增此列
--      此时库存约束应改为 CHECK (sold_tickets + locked_tickets <= total_tickets)
--   8. 幂等约束 UNIQUE(user_id, idempotent_key)：防用户重复点击造成重复下单
--   ⚠ 关键决策：sold_tickets 口径（含/不含待支付）尚未固化，直接决定走第 7 项与否，
--      逻辑设计阶段不定、开发阶段返工成本最高。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- MySQL 5.7 兼容说明
--   1. COLLATE utf8mb4_0900_ai_ci 需改为 utf8mb4_general_ci；
--   2. CHECK 约束在 5.7 会被解析但忽略，需改由应用层或触发器保证；
--   3. DATETIME(3) 与 CURRENT_TIMESTAMP(3) 支持，可保留。
-- ----------------------------------------------------------------------------
