# 抢票系统 ticket_db（LAB1031）

## 目录结构

```text
ticket_db/
├── ER图.png                 数据库 ER 图
└── sql/
    ├── schema.sql           建库 + 建 5 张表（整库重建脚本）
    ├── seed.sql             造数（用户/场次/票档/订单/触发器/存储过程）
    ├── query_basic.sql      视图 v_event_remain + 6 条基础查询
    └── query_adv.sql        5 条进阶查询 + EXPLAIN 索引验证
```
