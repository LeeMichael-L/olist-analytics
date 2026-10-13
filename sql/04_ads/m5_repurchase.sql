/* =====================================================================
   文件：m5_repurchase.sql
   模块：5 买家复购与价值（轻量版）
   业务问题：复购率是多少？平台增长靠新客还是老客？
   口径：已送达、分析窗口内、无状态矛盾的订单；买家用 customer_unique_id
   复购定义（D-022）：在 2 个及以上不同日期下过单的买家
   作者：LeeMichael-L    日期：2026-10-13
   ===================================================================== */

USE olist;

/* ---------------------------------------------------------------------
   查询1：两种定义下的复购率
   定义A：下过 2 单及以上；定义B：在 2 个及以上不同日期下过单
   结果：buyers 93,096 | A 2,789 (3.00%) | B 2,005 (2.15%)
   差异：784 个买家的多笔订单都在同一天（多为一次购物被拆成几单）
   --------------------------------------------------------------------- */
WITH valid_order AS (
    SELECT order_id, customer_unique_id, purchase_ts
    FROM dwd_orders
    WHERE order_status = 'delivered' AND in_analysis_window = 1 AND is_status_conflict = 0
),
buyer_summary AS (
    -- 每个买家一行
    SELECT customer_unique_id,
           COUNT(*)                          AS n_orders,
           COUNT(DISTINCT DATE(purchase_ts)) AS n_days
    FROM valid_order
    GROUP BY customer_unique_id
)
SELECT COUNT(*)            AS buyers,
       SUM(n_orders >= 2)  AS rep_buyers_a,
       AVG(n_orders >= 2)  AS rate_a,
       SUM(n_days >= 2)    AS rep_buyers_b,
       AVG(n_days >= 2)    AS rate_b
FROM buyer_summary;


/* ---------------------------------------------------------------------
   查询2：复购订单贡献了多少交易额
   复购订单：下单日期晚于该买家首次购买日期的订单
   结果：订单 96,203 | 复购订单 2,249 (2.34%) | 复购交易额占比 2.15%
   --------------------------------------------------------------------- */
WITH valid_order AS (
    SELECT order_id, customer_unique_id, purchase_ts
    FROM dwd_orders
    WHERE order_status = 'delivered' AND in_analysis_window = 1 AND is_status_conflict = 0
),
order_value AS (
    -- 每笔订单一行，带上订单金额
    SELECT v.order_id, v.customer_unique_id, v.purchase_ts, SUM(i.price) AS order_gmv
    FROM valid_order v
    JOIN dwd_order_items i USING (order_id)
    GROUP BY v.order_id, v.customer_unique_id, v.purchase_ts
),
order_flag AS (
    -- 窗口函数：在每笔订单旁边算出它所属买家的首次购买日期
    SELECT *,
           MIN(DATE(purchase_ts)) OVER (PARTITION BY customer_unique_id) AS first_day
    FROM order_value
)
SELECT COUNT(*)                                                     AS orders,
       SUM(order_gmv)                                               AS total_gmv,
       SUM(DATE(purchase_ts) > first_day)                           AS re_orders,
       AVG(DATE(purchase_ts) > first_day)                           AS rate_re_orders,
       SUM(CASE WHEN DATE(purchase_ts) > first_day THEN order_gmv ELSE 0 END)
         / SUM(order_gmv)                                           AS rate_re_gmv
FROM order_flag;


/* ---------------------------------------------------------------------
   查询3：右删失检查——按首次购买年份分组的复购率（定义B）
   结果：2017 年首购 42,134 人，复购率 3.10%；2018 年首购 50,962 人，1.37%
   结论：2018 年首购的买家观察时间短，复购率被低估；整体 2.15% 是下限
   --------------------------------------------------------------------- */
WITH valid_order AS (
    SELECT order_id, customer_unique_id, purchase_ts
    FROM dwd_orders
    WHERE order_status = 'delivered' AND in_analysis_window = 1 AND is_status_conflict = 0
),
buyer_summary AS (
    SELECT customer_unique_id,
           LEFT(MIN(purchase_ts), 4)         AS first_year,
           COUNT(DISTINCT DATE(purchase_ts)) AS n_days
    FROM valid_order
    GROUP BY customer_unique_id
)
SELECT first_year,
       COUNT(*)          AS buyers,
       SUM(n_days >= 2)  AS rep_buyers,
       AVG(n_days >= 2)  AS rate
FROM buyer_summary
GROUP BY first_year
ORDER BY first_year;
