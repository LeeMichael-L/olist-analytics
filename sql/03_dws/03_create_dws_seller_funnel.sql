/* =====================================================================
   文件：sql/03_dws/03_create_dws_seller_funnel.sql
   用途：模块7 卖家获取漏斗宽表 dws_seller_funnel（一行 = 一条营销线索 MQL）
   口径（D-031）：
     - 渠道：origin 为空的 60 条并入 'unknown'
     - 激活：签约后 90 天内至少有 1 笔有效订单（dws_order_fulfillment 中的订单）
     - 健康：签约后 90 天内至少有 3 笔有效订单（平均每月 1 单；模块6 发现一半卖家达不到）
     - 观察窗口：只有签约日期 ≤ 2018-06-02（分析窗口结束 2018-08-31 往前 90 天）的签约，
       才有完整的 90 天观察期，is_observable = 1；其余签约的激活、健康字段为 NULL（右删失）
   依赖：ods_mql、ods_closed_deals、dwd_order_items、dwd_orders、dws_order_fulfillment
   作者：LeeMichael-L    日期：2026-10-15

   ===================================================================== */

USE olist;

DROP TABLE IF EXISTS dws_seller_funnel;
CREATE TABLE dws_seller_funnel (
    mql_id               CHAR(32)     NOT NULL,
    origin               VARCHAR(32)  NOT NULL,  -- 获客渠道
    first_contact_date   DATE         NOT NULL,
    -- 签约
    is_won               TINYINT      NOT NULL,
    seller_id            CHAR(32)     NULL,
    won_date             DATE         NULL,
    days_to_won          SMALLINT     NULL,      -- 首次接触 → 签约
    is_observable        TINYINT      NULL,      -- 是否有完整 90 天观察期；未签约为 NULL
    -- 签约后的经营情况（只对 is_observable = 1 的签约有值）
    first_order_date     DATE         NULL,      -- 签约后第一笔有效订单
    days_to_first_order  SMALLINT     NULL,
    n_orders_90d         INT          NULL,      -- 签约后 90 天内的有效订单数
    is_activated_90d     TINYINT      NULL,      -- n_orders_90d >= 1
    is_healthy_90d       TINYINT      NULL,      -- n_orders_90d >= 3
    PRIMARY KEY (mql_id),
    INDEX idx_funnel_origin (origin)
) DEFAULT CHARSET = utf8mb4 COMMENT = 'DWS 卖家获取漏斗（模块7）';

INSERT INTO dws_seller_funnel
WITH seller_order AS (
    -- 每个卖家的每笔有效订单及下单时间（多卖家订单也计入，D-029 规模口径）
    SELECT DISTINCT i.seller_id, o.order_id, o.purchase_ts
    FROM dwd_order_items i
    JOIN dws_order_fulfillment f ON i.order_id = f.order_id
    JOIN dwd_orders o            ON i.order_id = o.order_id
),
deal AS (
    SELECT d.mql_id, d.seller_id, DATE(d.won_date) AS won_date,
           (d.won_date <= '2018-08-31' - INTERVAL 90 DAY) AS is_observable
    FROM ods_closed_deals d
),
deal_orders AS (
    -- 签约后 90 天内的订单
    SELECT dl.mql_id,
           MIN(so.purchase_ts) AS first_order_ts,
           COUNT(so.order_id)  AS n_orders_90d
    FROM deal dl
    LEFT JOIN seller_order so
           ON so.seller_id = dl.seller_id
          AND so.purchase_ts >= dl.won_date
          AND so.purchase_ts <  dl.won_date + INTERVAL 90 DAY
    GROUP BY dl.mql_id
)
SELECT m.mql_id,
       COALESCE(m.origin, 'unknown'),
       m.first_contact_date,
       (dl.mql_id IS NOT NULL),
       dl.seller_id,
       dl.won_date,
       DATEDIFF(dl.won_date, m.first_contact_date),
       dl.is_observable,
       CASE WHEN dl.is_observable = 1 THEN DATE(o.first_order_ts) END,
       CASE WHEN dl.is_observable = 1 THEN DATEDIFF(o.first_order_ts, dl.won_date) END,
       CASE WHEN dl.is_observable = 1 THEN o.n_orders_90d END,
       CASE WHEN dl.is_observable = 1 THEN (o.n_orders_90d >= 1) END,
       CASE WHEN dl.is_observable = 1 THEN (o.n_orders_90d >= 3) END
FROM ods_mql m
LEFT JOIN deal dl        ON m.mql_id = dl.mql_id
LEFT JOIN deal_orders o  ON m.mql_id = o.mql_id;

/* ---------------------------------------------------------------------
   核对
   --------------------------------------------------------------------- */
-- 1. 行数 = MQL 数 8,000；签约 842；可观察签约 667
SELECT COUNT(*)              AS mql,
       SUM(is_won)           AS won,
       SUM(is_observable)    AS observable,
       SUM(is_activated_90d) AS activated,
       SUM(is_healthy_90d)   AS healthy
FROM dws_seller_funnel;

-- 2. 右删失的证据：观察期不完整的签约，"签约后有过订单"的比例明显偏低
--    （这里不限 90 天，统计到分析窗口结束有没有订单）
SELECT f.is_observable,
       COUNT(*)                                        AS deals,
       SUM(EXISTS (SELECT 1
                   FROM dwd_order_items i
                   JOIN dws_order_fulfillment x ON i.order_id = x.order_id
                   WHERE i.seller_id = f.seller_id))   AS ever_sold,
       ROUND(AVG(EXISTS (SELECT 1
                   FROM dwd_order_items i
                   JOIN dws_order_fulfillment x ON i.order_id = x.order_id
                   WHERE i.seller_id = f.seller_id)), 4) AS ever_sold_rate
FROM dws_seller_funnel f
WHERE f.is_won = 1
GROUP BY f.is_observable;

-- 3. 数据质量：签约早于首次接触的记录
SELECT COUNT(*) AS won_before_contact
FROM dws_seller_funnel
WHERE days_to_won < 0;

-- 4. 签约卖家中，在整个订单数据集里一单都没有的（卖家表里查不到）
SELECT COUNT(*)                            AS won_sellers,
       SUM(s.seller_id IS NULL)            AS never_in_order_data,
       ROUND(AVG(s.seller_id IS NULL), 4)  AS never_rate
FROM dws_seller_funnel f
LEFT JOIN ods_sellers s ON f.seller_id = s.seller_id
WHERE f.is_won = 1;