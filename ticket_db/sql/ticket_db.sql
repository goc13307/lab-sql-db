-- ============================================================
-- 演出票务系统 ticket_db · 建库 + 建表脚本
-- 对应schema.sql
-- 依据：ticket_db表结构说明.xlsx
-- 表清单：user（用户）、event（场次）、seat_category（票档）、
--         ticket_order（订单）、notification（通知）
-- ============================================================

-- ---------- 建库 ----------
CREATE DATABASE IF NOT EXISTS ticket_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE ticket_db;

-- 重复执行时按外键依赖反序删表（子表 → 父表）
DROP TABLE IF EXISTS notification;
DROP TABLE IF EXISTS ticket_order;
DROP TABLE IF EXISTS seat_category;
DROP TABLE IF EXISTS `event`;
DROP TABLE IF EXISTS `user`;


-- ============================================================
-- 1. 用户表 user
--    手机号唯一且兼作登录标识与防刷号标识
-- ============================================================
CREATE TABLE `user` (
    user_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '用户编号',
    user_name VARCHAR(50)     NOT NULL                COMMENT '姓名',
    phone     VARCHAR(20)     NOT NULL                COMMENT '手机号（兼作登录与防刷号标识）',
    create_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '注册时间',
    PRIMARY KEY (user_id),
    UNIQUE KEY uk_user_phone (phone)                  -- 同一手机号只能注册一个账号
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '用户表';


-- ============================================================
-- 2. 场次表 event
--    status 取值域：0=待开售 1=预售中 2=已开售 3=已结束 4=已取消
-- ============================================================
CREATE TABLE `event` (
    event_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '场次编号',
    event_name VARCHAR(200)    NOT NULL                COMMENT '场次名称',
    event_time DATETIME(3)     NOT NULL                COMMENT '演出时间（开演时间）',
    venue      VARCHAR(200)    NOT NULL                COMMENT '场馆',
    status     TINYINT         NOT NULL DEFAULT 0      COMMENT '场次状态 0=待开售 1=预售中 2=已开售 3=已结束 4=已取消',
    PRIMARY KEY (event_id),
    KEY idx_event_status (status)                      -- 按状态筛选可售场次
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '场次表';


-- ============================================================
-- 3. 票档表 seat_category
--    票档不可脱离场次存在；一个场次下票档名称唯一
--    sold_tickets 为派生冗余量，由订单汇总/实时扣减维护
-- ============================================================
CREATE TABLE seat_category (
    category_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '票档编号',
    event_id      BIGINT UNSIGNED NOT NULL                COMMENT '所属场次编号（外键 → event.event_id）',
    category_name VARCHAR(100)    NOT NULL                COMMENT '票档名称',
    price         DECIMAL(10, 2)  NOT NULL                COMMENT '单价（金额禁用 FLOAT）',
    total_tickets INT UNSIGNED    NOT NULL                COMMENT '总票数',
    sold_tickets  INT UNSIGNED    NOT NULL DEFAULT 0      COMMENT '已售票数',
    PRIMARY KEY (category_id),
    UNIQUE KEY uk_sc_name (event_id, category_name),      -- 同一场次下票档名称不重复
    KEY idx_sc_event (event_id),                          -- 按场次查票档，并支撑外键
    CONSTRAINT fk_sc_event FOREIGN KEY (event_id) REFERENCES `event` (event_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,             -- 有票档的场次不允许删除
    CONSTRAINT chk_sc_price_nonneg CHECK (price >= 0),                    -- 单价非负
    CONSTRAINT chk_sc_total_positive CHECK (total_tickets > 0),           -- 总票数须为正
    CONSTRAINT chk_sc_sold_not_exceed CHECK (sold_tickets <= total_tickets) -- 防超卖底线
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '票档表';


-- ============================================================
-- 4. 订单表 ticket_order
--    一张订单只订购一个票档，用 quantity 表示购票数量
--    status 取值域：1=待支付 2=已支付 3=已取消 4=已超时
-- ============================================================
CREATE TABLE ticket_order (
    order_id    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '订单编号',
    user_id     BIGINT UNSIGNED NOT NULL                COMMENT '下单用户编号（外键 → user.user_id）',
    category_id BIGINT UNSIGNED NOT NULL                COMMENT '所订票档编号（外键 → seat_category.category_id）',
    order_time  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '下单时间',
    status      TINYINT         NOT NULL DEFAULT 1      COMMENT '订单状态 1=待支付 2=已支付 3=已取消 4=已超时',
    quantity    INT UNSIGNED    NOT NULL                COMMENT '购票数量',
    PRIMARY KEY (order_id),
    KEY idx_order_user (user_id, status),               -- 用户维度查订单/待支付单，并支撑外键
    KEY idx_order_category (category_id),               -- 票档维度统计销量，并支撑外键
    KEY idx_order_time (order_time),                    -- 按下单时间排序与范围查询
    CONSTRAINT fk_order_user FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,           -- 有订单的用户不允许删除
    CONSTRAINT fk_order_category FOREIGN KEY (category_id) REFERENCES seat_category (category_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,           -- 有订单的票档不允许删除
    CONSTRAINT chk_order_quantity_positive CHECK (quantity >= 1)  -- 至少购一张
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '订单表';


-- ============================================================
-- 5. 通知表 notification
--    一张订单可触发多条通知
--    user_id 为派生冗余：禁止独立写入，须与订单归属一致
--    is_read 取值域：0=未读 1=已读
-- ============================================================
CREATE TABLE notification (
    notify_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '通知编号',
    order_id  BIGINT UNSIGNED NOT NULL                COMMENT '触发通知的订单编号（外键 → ticket_order.order_id）',
    user_id   BIGINT UNSIGNED NOT NULL                COMMENT '接收用户编号（外键 → user.user_id，派生冗余，须与订单归属一致）',
    content   VARCHAR(500)    NOT NULL                COMMENT '通知内容',
    create_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT '生成时间',
    is_read   TINYINT(1)      NOT NULL DEFAULT 0      COMMENT '是否已读 0=未读 1=已读',
    PRIMARY KEY (notify_id),
    KEY idx_noti_order (order_id),                    -- 按订单查通知，并支撑外键
    KEY idx_noti_user (user_id, is_read, create_at),  -- 用户未读消息列表（最左列同时支撑 user_id 外键）
    CONSTRAINT fk_noti_order FOREIGN KEY (order_id) REFERENCES ticket_order (order_id)
        ON DELETE CASCADE ON UPDATE CASCADE,            -- 订单删除时其通知一并清理
    CONSTRAINT fk_noti_user FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE CASCADE            -- 有通知的用户不允许删除
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_0900_ai_ci
  COMMENT = '通知表';
