/* =====================================================================
   文件：sql/03_dws/02_create_dws_seller.sql
   用途：模块6 卖家宽表 dws_seller（一行 = 一个卖家）
   范围：在有效订单（dws_order_fulfillment 的 96,203 单）中至少卖出过 1 件商品的卖家
   口径：
     - 规模指标（GMV、件数、订单数、品类）：按商品行归属，多卖家订单按各自商品计入各卖家
     - 体验指标（差评、延误、发货超时）：只用单卖家订单（D-029，与 D-025 一致）
     - 取消率：分析窗口内涉及该卖家的全部订单中，状态为 canceled 的占比
     - 不在本层做最小样本过滤，保留 n_reviewed 等分母字段，由分析时决定门槛
   依赖：dwd_order_items、dwd_orders、dwd_sellers、dws_order_fulfillment
   作者：LeeMichael-L    日期：2026-10-15
   ===================================================================== */

USE olist;

DROP TABLE IF EXISTS dws_seller;
CREATE TABLE dws_seller (
    seller_id            CHAR(32)      NOT NULL,
    seller_state         CHAR(2)       NOT NULL,
    -- 活跃度
    first_order_date     DATE          NOT NULL,
    last_order_date      DATE          NOT NULL,
    active_months        SMALLINT      NOT NULL,  -- 有成交的月份数
    -- 规模（含多卖家订单）
    n_orders             INT           NOT NULL,  -- 有效订单数
    n_items              INT           NOT NULL,  -- 售出件数
    gmv                  DECIMAL(12,2) NOT NULL,  -- SUM(price)
    avg_item_price       DECIMAL(10,2) NOT NULL,
    n_categories         SMALLINT      NOT NULL,
    main_category        VARCHAR(64)   NOT NULL,  -- GMV 最大的品类
    -- 体验（只用单卖家订单，D-029）
    n_single_orders      INT           NOT NULL,  -- 单卖家订单数（体验指标的总样本）
    n_reviewed           INT           NOT NULL,  -- 其中有评价的订单数（差评率的分母）
    n_bad_reviews        INT           NOT NULL,
    bad_rate             DECIMAL(6,4)  NULL,      -- n_reviewed = 0 时为 NULL
    avg_score            DECIMAL(4,2)  NULL,
    n_late               INT           NOT NULL,
    late_rate            DECIMAL(6,4)  NULL,
    n_seller_late        INT           NOT NULL,
    seller_late_rate     DECIMAL(6,4)  NULL,      -- 分母为 is_seller_late 非 NULL 的订单
    avg_seller_days      DECIMAL(5,1)  NULL,
    -- 取消
    n_orders_all_status  INT           NOT NULL,  -- 窗口内涉及该卖家的全部订单（任意状态）
    n_canceled           INT           NOT NULL,
    cancel_rate          DECIMAL(6,4)  NOT NULL,
    PRIMARY KEY (seller_id),
    INDEX idx_dws_seller_state (seller_state)
) COMMENT = 'DWS 卖家宽表（模块6）';

INSERT INTO dws_seller
WITH item_valid AS (
    -- 有效订单中的商品行
    SELECT i.seller_id, i.order_id, i.category_en, i.price, f.purchase_month,
           DATE(o.purchase_ts) AS purchase_date
    FROM dwd_order_items i
    JOIN dws_order_fulfillment f ON i.order_id = f.order_id
    JOIN dwd_orders o            ON i.order_id = o.order_id
),
scale AS (
    SELECT seller_id,
           MIN(purchase_date)              AS first_order_date,
           MAX(purchase_date)              AS last_order_date,
           COUNT(DISTINCT purchase_month)  AS active_months,
           COUNT(DISTINCT order_id)        AS n_orders,
           COUNT(*)                        AS n_items,
           SUM(price)                      AS gmv,
           COUNT(DISTINCT category_en)     AS n_categories
    FROM item_valid
    GROUP BY seller_id
),
main_cat AS (
    -- 每个卖家 GMV 最大的品类；并列时按品类名取一个
    SELECT seller_id, category_en
    FROM (
        SELECT seller_id, category_en,
               ROW_NUMBER() OVER (PARTITION BY seller_id
                                  ORDER BY SUM(price) DESC, category_en) AS rn
        FROM item_valid
        GROUP BY seller_id, category_en
    ) t
    WHERE rn = 1
),
experience AS (
    -- 单卖家订单：dws_order_fulfillment.seller_id 只对单卖家订单有值
    SELECT seller_id,
           COUNT(*)                          AS n_single_orders,
           SUM(has_review)                   AS n_reviewed,
           COALESCE(SUM(is_bad_review), 0)   AS n_bad_reviews,
           AVG(is_bad_review)                AS bad_rate,
           AVG(review_score)                 AS avg_score,
           SUM(is_late)                      AS n_late,
           AVG(is_late)                      AS late_rate,
           COALESCE(SUM(is_seller_late), 0)  AS n_seller_late,
           AVG(is_seller_late)               AS seller_late_rate,
           AVG(seller_days)                  AS avg_seller_days
    FROM dws_order_fulfillment
    WHERE seller_id IS NOT NULL
    GROUP BY seller_id
),
cancel AS (
    -- 分析窗口内涉及该卖家的全部订单（任意状态）
    SELECT i.seller_id,
           COUNT(DISTINCT i.order_id)                                                AS n_orders_all_status,
           COUNT(DISTINCT CASE WHEN o.order_status = 'canceled' THEN i.order_id END) AS n_canceled
    FROM dwd_order_items i
    JOIN dwd_orders o ON i.order_id = o.order_id
    WHERE o.in_analysis_window = 1
    GROUP BY i.seller_id
)
SELECT s.seller_id,
       sl.state,
       s.first_order_date,
       s.last_order_date,
       s.active_months,
       s.n_orders,
       s.n_items,
       s.gmv,
       ROUND(s.gmv / s.n_items, 2),
       s.n_categories,
       m.category_en,
       COALESCE(e.n_single_orders, 0),
       COALESCE(e.n_reviewed, 0),
       COALESCE(e.n_bad_reviews, 0),
       e.bad_rate,
       e.avg_score,
       COALESCE(e.n_late, 0),
       e.late_rate,
       COALESCE(e.n_seller_late, 0),
       e.seller_late_rate,
       e.avg_seller_days,
       c.n_orders_all_status,
       c.n_canceled,
       c.n_canceled / c.n_orders_all_status
FROM scale s
JOIN dwd_sellers sl    ON s.seller_id = sl.seller_id
JOIN main_cat m        ON s.seller_id = m.seller_id
LEFT JOIN experience e ON s.seller_id = e.seller_id   -- 只卖过多卖家订单的卖家（20 个）在这里没有记录
JOIN cancel c          ON s.seller_id = c.seller_id;

/* ---------------------------------------------------------------------
   核对
   --------------------------------------------------------------------- */
-- 1. 总量：GMV 应等于 13,179,777.95；单卖家订单合计应等于 96,203 − 1,272 = 94,931
SELECT COUNT(*)                AS sellers,
       SUM(gmv)                AS total_gmv,
       SUM(n_items)            AS total_items,
       SUM(n_single_orders)    AS single_orders,
       SUM(n_reviewed)         AS reviewed,
       SUM(n_bad_reviews)      AS bad_reviews,
       SUM(n_late)             AS late_orders
FROM dws_seller;

-- 2. 订单数不可加：SUM(n_orders) 会比 96,203 多，多出的部分来自多卖家订单
SELECT SUM(n_orders)         AS sum_n_orders,
       SUM(n_orders) - 96203 AS extra_from_multi_seller
FROM dws_seller;

-- 3. 样本量分布：体验指标有多少卖家"样本够用"
SELECT SUM(n_reviewed = 0)               AS no_review,
       SUM(n_reviewed BETWEEN 1 AND 9)   AS r_1_9,
       SUM(n_reviewed BETWEEN 10 AND 29) AS r_10_29,
       SUM(n_reviewed >= 30)             AS r_30_plus
FROM dws_seller;