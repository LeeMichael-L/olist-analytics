/* =====================================================================
   文件：01_create_dws_order_fulfillment.sql
   阶段：S2 · DWS 汇总层 · 模块3 履约与满意度
   目的：建立履约宽表，每笔有效已送达订单一行，提前算好模块3需要的
         所有字段，后续分析只查这一张表
   范围：order_status = 'delivered' AND in_analysis_window = 1
         AND is_status_conflict = 0（96,203 单）
   输入：dwd_orders、dwd_order_items、dwd_order_reviews、dwd_sellers、
         dwd_customers
   输出：dws_order_fulfillment
   对应决策：
     D-023 卖家发货超时：单卖家订单比较交物流时间与发货截止时间；多卖家为 NULL
     D-024 无评价订单保留在宽表，review_score 为 NULL，用 has_review 标记
     D-025 多卖家订单的 seller_state / is_cross_state 为 NULL；
           另存交易额最大卖家的州（*_top），供敏感性分析
     D-026 环节时长按日期计算，结果为负数时记为 NULL
   环境：MySQL 26.7（兼容 MySQL 8.0 及以上）
   作者：LeeMichael-L    日期：2026-10-14
   ===================================================================== */

USE olist;

DROP TABLE IF EXISTS dws_order_fulfillment;
CREATE TABLE dws_order_fulfillment (
    order_id                   CHAR(32)      NOT NULL,
    purchase_month             CHAR(7)       NOT NULL,
    customer_unique_id         CHAR(32)      NOT NULL,
    -- 地理
    customer_state             CHAR(2)       NOT NULL,
    seller_id                  CHAR(32)      NULL,      -- 只对单卖家订单有值
    seller_state               CHAR(2)       NULL,      -- 只对单卖家订单有值（D-025）
    is_cross_state             TINYINT       NULL,      -- 买家州 ≠ 卖家州；多卖家为 NULL
    seller_state_top           CHAR(2)       NOT NULL,  -- 交易额最大卖家的州（敏感性分析用）
    is_cross_state_top         TINYINT       NOT NULL,
    distance_km                DECIMAL(8,1)  NULL,      -- 买卖双方直线距离；单卖家且双方坐标齐全时有值
    -- 订单规模
    n_items                    SMALLINT      NOT NULL,
    order_gmv                  DECIMAL(10,2) NOT NULL,  -- SUM(price)
    order_freight              DECIMAL(10,2) NOT NULL,  -- SUM(freight_value)
    -- 履约各环节时长（天，按日期计算；负数记为 NULL，D-026）
    approve_days               SMALLINT      NULL,      -- 下单 → 审核通过
    seller_days                SMALLINT      NULL,      -- 审核通过 → 交给物流（卖家处理）
    transit_days               SMALLINT      NULL,      -- 交给物流 → 买家收货（物流运输）
    delivery_days              SMALLINT      NOT NULL,  -- 下单 → 买家收货
    delay_days                 SMALLINT      NOT NULL,  -- 收货日期 − 承诺日期，提前为负
    is_late                    TINYINT       NOT NULL,  -- delay_days > 0
    is_seller_late             TINYINT       NULL,      -- 交物流晚于发货截止时间（D-023）
    -- 评价（D-024）
    has_review                 TINYINT       NOT NULL,
    review_score               TINYINT       NULL,
    first_review_score         TINYINT       NULL,
    is_bad_review              TINYINT       NULL,      -- review_score <= 2
    -- 继承的标记字段
    is_multi_seller            TINYINT       NOT NULL,
    has_ts_anomaly             TINYINT       NOT NULL,
    is_review_before_delivery  TINYINT       NULL,
    is_multi_review            TINYINT       NULL,
    PRIMARY KEY (order_id),
    INDEX idx_dws_ful_month (purchase_month),
    INDEX idx_dws_ful_seller (seller_id)
) COMMENT = 'DWS 订单履约宽表（模块3）';

INSERT INTO dws_order_fulfillment
WITH valid_order AS (
    SELECT *
    FROM dwd_orders
    WHERE order_status = 'delivered' AND in_analysis_window = 1 AND is_status_conflict = 0
),
item_by_order AS (
    -- 订单级：件数、金额、运费、发货截止时间
    -- 单卖家订单各商品的截止时间全部相同，MIN 与 MAX 一致（D-023 的数据依据）
    SELECT order_id,
           COUNT(*)                AS n_items,
           SUM(price)              AS order_gmv,
           SUM(freight_value)      AS order_freight,
           MIN(shipping_limit_ts)  AS shipping_limit_ts,
           MIN(seller_id)          AS any_seller_id
    FROM dwd_order_items
    GROUP BY order_id
),
seller_rank AS (
    -- 每个订单内按卖家交易额排序，取第一名（并列时按 seller_id 取一个）
    SELECT order_id, seller_id,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY SUM(price) DESC, seller_id) AS rn
    FROM dwd_order_items
    GROUP BY order_id, seller_id
)
SELECT
    o.order_id,
    o.purchase_month,
    o.customer_unique_id,
    o.customer_state,
    -- 单卖家订单才填卖家信息
    CASE WHEN o.is_multi_seller = 0 THEN i.any_seller_id END,
    CASE WHEN o.is_multi_seller = 0 THEN s.state END,
    CASE WHEN o.is_multi_seller = 0 THEN (o.customer_state <> s.state) END,
    st.state,
    (o.customer_state <> st.state),
    -- haversine 公式：地球半径 6371 km
    CASE WHEN o.is_multi_seller = 0 THEN
        ROUND(6371 * 2 * ASIN(SQRT(
            POW(SIN(RADIANS(s.lat - c.lat) / 2), 2)
          + COS(RADIANS(c.lat)) * COS(RADIANS(s.lat))
          * POW(SIN(RADIANS(s.lng - c.lng) / 2), 2))), 1)
    END,
    i.n_items,
    i.order_gmv,
    i.order_freight,
    -- 环节时长：负数记为 NULL（D-026）；任一时间戳为 NULL 时结果也为 NULL
    CASE WHEN DATEDIFF(o.approved_ts, o.purchase_ts) >= 0
         THEN DATEDIFF(o.approved_ts, o.purchase_ts) END,
    CASE WHEN DATEDIFF(o.delivered_carrier_ts, o.approved_ts) >= 0
         THEN DATEDIFF(o.delivered_carrier_ts, o.approved_ts) END,
    CASE WHEN DATEDIFF(o.delivered_customer_ts, o.delivered_carrier_ts) >= 0
         THEN DATEDIFF(o.delivered_customer_ts, o.delivered_carrier_ts) END,
    DATEDIFF(o.delivered_customer_ts, o.purchase_ts),
    DATEDIFF(o.delivered_customer_ts, o.estimated_delivery_date),
    DATEDIFF(o.delivered_customer_ts, o.estimated_delivery_date) > 0,
    -- 卖家发货超时：单卖家且有交物流时间才判断（D-023）
    CASE WHEN o.is_multi_seller = 0 AND o.delivered_carrier_ts IS NOT NULL
         THEN o.delivered_carrier_ts > i.shipping_limit_ts END,
    -- 评价（D-024）
    r.order_id IS NOT NULL,
    r.review_score,
    r.first_review_score,
    r.review_score <= 2,
    o.is_multi_seller,
    o.has_ts_anomaly,
    r.is_review_before_delivery,
    r.is_multi_review
FROM valid_order o
JOIN item_by_order i       ON o.order_id = i.order_id
JOIN seller_rank sr        ON o.order_id = sr.order_id AND sr.rn = 1
JOIN dwd_sellers st        ON sr.seller_id = st.seller_id
LEFT JOIN dwd_sellers s    ON i.any_seller_id = s.seller_id
JOIN dwd_customers c       ON o.customer_id = c.customer_id
LEFT JOIN dwd_order_reviews r ON o.order_id = r.order_id;

/* ---------------------------------------------------------------------
   核对：与已知数字对照
   --------------------------------------------------------------------- */
SELECT COUNT(*)                     AS orders,            -- 预期 96,203
       SUM(order_gmv)               AS gmv,               -- 预期 13,179,777.95
       SUM(has_review)              AS with_review,       -- 预期 95,560
       SUM(is_multi_seller)         AS multi_seller,      -- 预期 1,272
       ROUND(AVG(is_late), 4)       AS late_rate,         -- 预期 0.0679（1 − 按时送达率 93.2%）
       ROUND(AVG(is_bad_review), 4) AS bad_review_rate    -- 预期 0.1280（(9,313 + 2,915) ÷ 95,560）
FROM dws_order_fulfillment;

-- NULL 的数量：每一项都应能解释来源
SELECT SUM(seller_state IS NULL)    AS null_seller_state,   -- = 多卖家订单数
       SUM(distance_km IS NULL)     AS null_distance,       -- 多卖家 + 坐标缺失
       SUM(approve_days IS NULL)    AS null_approve,        -- 审核时间缺失
       SUM(seller_days IS NULL)     AS null_seller_days,    -- 审核/交物流缺失 + 负数
       SUM(transit_days IS NULL)    AS null_transit_days,   -- 交物流缺失 + 负数
       SUM(is_seller_late IS NULL)  AS null_seller_late,    -- 多卖家 + 交物流缺失
       SUM(review_score IS NULL)    AS null_review          -- = 无评价订单数
FROM dws_order_fulfillment;