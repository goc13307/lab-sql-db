# 抢票系统 ticket_db（LAB1031）

## 目录结构

```text
ticket_db/
├── ER图.png                     数据库 ER 图
└── sql/
    ├── schema.sql               建库 + 建 5 张表（整库重建脚本）
    ├── seed.sql                 造数（用户/场次/票档/订单/触发器/存储过程）
    ├── query_basic.sql          视图 v_event_remain + 6 条基础查询
    ├── query_adv.sql            5 条进阶查询 + EXPLAIN 索引验证
    ├── sp_grab_ticket.sql       抢票存储过程（事务内扣库存 + 下单，防超卖）
    └── sp_grab_ticket_verify.sql  sp_grab_ticket 验证用例（返回码 0/1/2/3）
```

## 执行顺序

```sql
SOURCE ticket_db/sql/schema.sql;                -- 建库建表（会 DROP DATABASE）
SOURCE ticket_db/sql/seed.sql;                  -- 造数
SOURCE ticket_db/sql/query_basic.sql;           -- 视图 + 基础查询
SOURCE ticket_db/sql/query_adv.sql;             -- 进阶查询
SOURCE ticket_db/sql/sp_grab_ticket.sql;        -- 抢票存储过程（可重复执行）
SOURCE ticket_db/sql/sp_grab_ticket_verify.sql; -- 验证返回码，跑完自动清理测试数据
```

## sp_grab_ticket 返回码

| 返回码 | 含义 |
|--------|------|
| 0 | 抢票成功（库存已扣、订单已生成） |
| 1 | 参数非法（任一项为 NULL，或数量为 0） |
| 2 | 库存不足（含票档不存在、场次与票档不匹配） |
| 3 | 系统异常（SQL 异常，事务已回滚） |

调用示例：

```sql
SET @rc = NULL;
CALL sp_grab_ticket(1, 1, 1, 2, @rc);
SELECT @rc;
```

## 注意事项

- 所有 SQL 文件均为 **UTF-8** 编码，执行时请带 `--default-character-set=utf8mb4`。
- 命令行执行含 `DELIMITER` 的脚本，请用输入重定向（`< 文件`），不要用 `-e "SOURCE ..."`。
- `sp_grab_ticket_verify.sql` 会产生临时订单，但结束时会精确删除并回滚库存，不污染 5000 单基线。
