/* =====================================================================
   文件：01_create_dwd_tables.sql
   阶段：S1 · DWD 明细数据层
   目的：根据数据质量审计的结论，把 ODS 数据清洗成可直接分析的明细表
   输入：ods_* 主数据集表
   输出：dwd_geo_zip、dwd_customers、dwd_sellers、dwd_products、
         dwd_orders、dwd_order_items、dwd_order_reviews
   原则：
     1. 只打标记，不删数据：有问题的记录保留并加标记字段（is_ / has_ 开头），
        由分析时用 WHERE 决定是否排除，便于做敏感性分析
     2. 数据已清洗，因此 DWD 层设主键：如果主键冲突导致建表失败，
        说明清洗逻辑有错误，主键在这里起到"自动检查"的作用
     3. 先显式定义表结构，再 INSERT ... SELECT 写入数据，字段类型清楚可控
   对应决策：D-013 至 D-021（见 docs/decision_log.md）
   环境：MySQL 26.7（兼容 MySQL 8.0 及以上）
   作者：LeeMichael-L    日期：2026-10-12
   ===================================================================== */

USE olist;

/* ---------------------------------------------------------------------
   1. 邮编坐标表：一行 = 一个邮编前缀（D-019：取平均经纬度）
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_geo_zip;
CREATE TABLE dwd_geo_zip (
    zip_code_prefix  CHAR(5)  NOT NULL,
    lat              DOUBLE   NOT NULL,
    lng              DOUBLE   NOT NULL,
    n_points         INT      NOT NULL,  -- 原始坐标点数量，便于追溯
    PRIMARY KEY (zip_code_prefix)
) COMMENT = 'DWD 邮编代表坐标';

INSERT INTO dwd_geo_zip
SELECT geolocation_zip_code_prefix,
       AVG(geolocation_lat),
       AVG(geolocation_lng),
       COUNT(*)
FROM ods_geolocation
GROUP BY geolocation_zip_code_prefix;

/* ---------------------------------------------------------------------
   2. 客户表：一行 = 一个 customer_id（关联邮编坐标）
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_customers;
CREATE TABLE dwd_customers (
    customer_id         CHAR(32)    NOT NULL,
    customer_unique_id  CHAR(32)    NOT NULL,
    zip_code_prefix     CHAR(5)     NOT NULL,
    city                VARCHAR(64) NOT NULL,
    state               CHAR(2)     NOT NULL,
    lat                 DOUBLE      NULL,     -- 邮编在地理表中找不到时为 NULL
    lng                 DOUBLE      NULL,
    PRIMARY KEY (customer_id),
    INDEX idx_dwd_cust_unique (customer_unique_id)
) COMMENT = 'DWD 客户';

INSERT INTO dwd_customers
SELECT c.customer_id,
       c.customer_unique_id,
       c.customer_zip_code_prefix,
       c.customer_city,
       c.customer_state,
       g.lat,
       g.lng
FROM ods_customers c
LEFT JOIN dwd_geo_zip g
       ON c.customer_zip_code_prefix = g.zip_code_prefix;

/* ---------------------------------------------------------------------
   3. 卖家表：一行 = 一个卖家（关联邮编坐标）
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_sellers;
CREATE TABLE dwd_sellers (
    seller_id        CHAR(32)    NOT NULL,
    zip_code_prefix  CHAR(5)     NOT NULL,
    city             VARCHAR(64) NOT NULL,
    state            CHAR(2)     NOT NULL,
    lat              DOUBLE      NULL,
    lng              DOUBLE      NULL,
    PRIMARY KEY (seller_id)
) COMMENT = 'DWD 卖家';

INSERT INTO dwd_sellers
SELECT s.seller_id,
       s.seller_zip_code_prefix,
       s.seller_city,
       s.seller_state,
       g.lat,
       g.lng
FROM ods_sellers s
LEFT JOIN dwd_geo_zip g
       ON s.seller_zip_code_prefix = g.zip_code_prefix;

/* ---------------------------------------------------------------------
   4. 商品表：一行 = 一个商品
      D-018：补2个缺失翻译；缺失品类记为 unknown；修正 lenght 拼写
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_products;
CREATE TABLE dwd_products (
    product_id                  CHAR(32)    NOT NULL,
    category_pt                 VARCHAR(64) NOT NULL,  -- 葡萄牙语品类名
    category_en                 VARCHAR(64) NOT NULL,  -- 英语品类名
    product_name_length         SMALLINT    NULL,
    product_description_length  SMALLINT    NULL,
    product_photos_qty          SMALLINT    NULL,
    product_weight_g            INT         NULL,
    product_length_cm           SMALLINT    NULL,
    product_height_cm           SMALLINT    NULL,
    product_width_cm            SMALLINT    NULL,
    PRIMARY KEY (product_id),
    INDEX idx_dwd_prod_cat (category_en)
) COMMENT = 'DWD 商品';

INSERT INTO dwd_products
SELECT p.product_id,
       COALESCE(p.product_category_name, 'unknown'),
       COALESCE(t.product_category_name_english, 'unknown'),
       p.product_name_lenght,
       p.product_description_lenght,
       p.product_photos_qty,
       p.product_weight_g,
       p.product_length_cm,
       p.product_height_cm,
       p.product_width_cm
FROM ods_products p
LEFT JOIN (
    -- 官方翻译表 + 手动补充的2个翻译
    SELECT product_category_name, product_category_name_english
    FROM ods_category_translation
    UNION ALL SELECT 'pc_gamer', 'pc_gamer'
    UNION ALL SELECT 'portateis_cozinha_e_preparadores_de_alimentos',
                     'portable_kitchen_food_processors'
) t ON p.product_category_name = t.product_category_name;

/* ---------------------------------------------------------------------
   5. 订单表：一行 = 一笔订单
      关联买家身份；加入分析窗口、时间戳异常、状态矛盾、多卖家等标记
      D-014、D-015、D-016、D-017
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_orders;
CREATE TABLE dwd_orders (
    order_id                       CHAR(32)    NOT NULL,
    customer_id                    CHAR(32)    NOT NULL,
    customer_unique_id             CHAR(32)    NOT NULL,  -- 真实买家
    customer_state                 CHAR(2)     NOT NULL,
    order_status                   VARCHAR(20) NOT NULL,
    purchase_ts                    DATETIME    NOT NULL,  -- 下单时间
    purchase_month                 CHAR(7)     NOT NULL,  -- 下单月份，如 2017-11
    approved_ts                    DATETIME    NULL,
    delivered_carrier_ts           DATETIME    NULL,
    delivered_customer_ts          DATETIME    NULL,
    estimated_delivery_date        DATE        NOT NULL,  -- 原数据时间部分全为 00:00:00
    n_items                        SMALLINT    NOT NULL,  -- 商品件数；无商品的订单为 0
    n_sellers                      SMALLINT    NOT NULL,  -- 卖家数
    -- 标记字段：1 = 是，0 = 否
    in_analysis_window             TINYINT     NOT NULL,  -- D-016
    is_multi_seller                TINYINT     NOT NULL,  -- D-017
    is_status_conflict             TINYINT     NOT NULL,  -- D-015
    is_carrier_before_purchase     TINYINT     NOT NULL,  -- D-014
    is_carrier_before_approved     TINYINT     NOT NULL,  -- D-014
    is_delivered_before_carrier    TINYINT     NOT NULL,  -- D-014
    has_ts_anomaly                 TINYINT     NOT NULL,  -- 以上三类任一成立
    PRIMARY KEY (order_id),
    INDEX idx_dwd_orders_buyer (customer_unique_id),
    INDEX idx_dwd_orders_month (purchase_month)
) COMMENT = 'DWD 订单';

INSERT INTO dwd_orders
SELECT o.order_id,
       o.customer_id,
       c.customer_unique_id,
       c.customer_state,
       o.order_status,
       o.order_purchase_timestamp,
       DATE_FORMAT(o.order_purchase_timestamp, '%Y-%m'),
       o.order_approved_at,
       o.order_delivered_carrier_date,
       o.order_delivered_customer_date,
       DATE(o.order_estimated_delivery_date),
       COALESCE(i.n_items, 0),
       COALESCE(i.n_sellers, 0),
       -- 分析窗口：2017-01-01 至 2018-08-31
       (o.order_purchase_timestamp >= '2017-01-01'
        AND o.order_purchase_timestamp < '2018-09-01'),
       COALESCE(i.n_sellers, 0) > 1,
       -- 状态矛盾：已送达却无送达时间，或未送达却有送达时间
       ((o.order_status = 'delivered'  AND o.order_delivered_customer_date IS NULL)
        OR (o.order_status <> 'delivered' AND o.order_delivered_customer_date IS NOT NULL)),
       -- 比较时任一方为 NULL 结果为 NULL，用 COALESCE 记为 0
       COALESCE(o.order_delivered_carrier_date  < o.order_purchase_timestamp, 0),
       COALESCE(o.order_delivered_carrier_date  < o.order_approved_at, 0),
       COALESCE(o.order_delivered_customer_date < o.order_delivered_carrier_date, 0),
       COALESCE(o.order_delivered_carrier_date  < o.order_purchase_timestamp, 0)
         OR COALESCE(o.order_delivered_carrier_date  < o.order_approved_at, 0)
         OR COALESCE(o.order_delivered_customer_date < o.order_delivered_carrier_date, 0)
FROM ods_orders o
JOIN ods_customers c
     ON o.customer_id = c.customer_id
LEFT JOIN (
    -- 先把订单商品汇总到订单粒度，再连接，避免订单行被放大
    SELECT order_id,
           COUNT(*)                  AS n_items,
           COUNT(DISTINCT seller_id) AS n_sellers
    FROM ods_order_items
    GROUP BY order_id
) i ON o.order_id = i.order_id;

/* ---------------------------------------------------------------------
   6. 订单商品表：一行 = 订单里的一件商品（关联品类）
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_order_items;
CREATE TABLE dwd_order_items (
    order_id             CHAR(32)      NOT NULL,
    order_item_id        SMALLINT      NOT NULL,
    product_id           CHAR(32)      NOT NULL,
    seller_id            CHAR(32)      NOT NULL,
    category_en          VARCHAR(64)   NOT NULL,
    shipping_limit_ts    DATETIME      NOT NULL,  -- 卖家发货截止时间
    price                DECIMAL(10,2) NOT NULL,
    freight_value        DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id),
    INDEX idx_dwd_items_seller (seller_id),
    INDEX idx_dwd_items_product (product_id)
) COMMENT = 'DWD 订单商品';

INSERT INTO dwd_order_items
SELECT i.order_id,
       i.order_item_id,
       i.product_id,
       i.seller_id,
       p.category_en,
       i.shipping_limit_date,
       i.price,
       i.freight_value
FROM ods_order_items i
JOIN dwd_products p
     ON i.product_id = p.product_id;

/* ---------------------------------------------------------------------
   7. 评价表：一行 = 一笔订单（粒度从"一条评价"变为"一笔订单"）
      D-013：每单保留最后作答的一条，同时保留第一条的分数供敏感性分析
      D-021：标记问卷是否早于送达
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS dwd_order_reviews;
CREATE TABLE dwd_order_reviews (
    order_id                   CHAR(32)  NOT NULL,
    review_id                  CHAR(32)  NOT NULL,  -- 保留的那条评价
    review_score               TINYINT   NOT NULL,  -- 最后作答的评分（主分析用）
    first_review_score         TINYINT   NOT NULL,  -- 第一次作答的评分（敏感性分析用）
    n_reviews                  TINYINT   NOT NULL,  -- 原始评价条数
    review_creation_date       DATE      NOT NULL,  -- 问卷发送日期（原数据有85条带时间，统一截取日期）
    review_answer_ts           DATETIME  NOT NULL,  -- 买家作答时间
    review_comment_message     TEXT      NULL,
    has_comment                TINYINT   NOT NULL,
    is_multi_review            TINYINT   NOT NULL,  -- D-013
    is_review_before_delivery  TINYINT   NOT NULL,  -- D-021
    PRIMARY KEY (order_id)
) COMMENT = 'DWD 订单评价（每单一行）';

INSERT INTO dwd_order_reviews
SELECT r.order_id,
       r.review_id,
       r.review_score,
       r.first_review_score,
       r.n_reviews,
       DATE(r.review_creation_date),
       r.review_answer_timestamp,
       r.review_comment_message,
       r.review_comment_message IS NOT NULL,
       r.n_reviews > 1,
       COALESCE(DATE(r.review_creation_date) < DATE(o.order_delivered_customer_date), 0)
FROM (
    SELECT rv.*,
           -- 按作答时间倒序编号：rn_last = 1 是最后作答的一条
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC, review_id DESC) AS rn_last,
           -- 第一次作答的分数
           FIRST_VALUE(review_score) OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp, review_id)           AS first_review_score,
           COUNT(*) OVER (PARTITION BY order_id)                                     AS n_reviews
    FROM ods_order_reviews rv
) r
JOIN ods_orders o
     ON r.order_id = o.order_id
WHERE r.rn_last = 1;

/* ---------------------------------------------------------------------
   8. 核对：DWD 与 ODS 的行数关系
   --------------------------------------------------------------------- */
SELECT 'dwd_geo_zip'       AS table_name, COUNT(*) AS dwd_rows,
       (SELECT COUNT(DISTINCT geolocation_zip_code_prefix) FROM ods_geolocation) AS expected_rows
FROM dwd_geo_zip
UNION ALL
SELECT 'dwd_customers',     COUNT(*), (SELECT COUNT(*) FROM ods_customers)     FROM dwd_customers
UNION ALL
SELECT 'dwd_sellers',       COUNT(*), (SELECT COUNT(*) FROM ods_sellers)       FROM dwd_sellers
UNION ALL
SELECT 'dwd_products',      COUNT(*), (SELECT COUNT(*) FROM ods_products)      FROM dwd_products
UNION ALL
SELECT 'dwd_orders',        COUNT(*), (SELECT COUNT(*) FROM ods_orders)        FROM dwd_orders
UNION ALL
SELECT 'dwd_order_items',   COUNT(*), (SELECT COUNT(*) FROM ods_order_items)   FROM dwd_order_items
UNION ALL
SELECT 'dwd_order_reviews', COUNT(*), (SELECT COUNT(DISTINCT order_id) FROM ods_order_reviews)
FROM dwd_order_reviews;

-- 标记字段汇总：与审计结果对照
SELECT SUM(in_analysis_window)          AS in_window,
       SUM(is_multi_seller)             AS multi_seller,
       SUM(is_status_conflict)          AS status_conflict,
       SUM(is_carrier_before_approved)  AS carrier_before_approved,
       SUM(has_ts_anomaly)              AS ts_anomaly
FROM dwd_orders;

SELECT SUM(is_multi_review)                     AS multi_review,
       SUM(review_score <> first_review_score)  AS score_changed,
       SUM(is_review_before_delivery)           AS review_before_delivery
FROM dwd_order_reviews;

SELECT SUM(category_en = 'unknown')             AS unknown_category_products,
       COUNT(DISTINCT category_en)              AS n_categories
FROM dwd_products;