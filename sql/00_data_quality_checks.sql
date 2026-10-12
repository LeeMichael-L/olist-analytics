/* =====================================================================
   文件：00_data_quality_checks.sql
   阶段：S1 · 数据质量审计
   目的：在 ODS 层系统检查数据问题，为 DWD 层的清洗规则提供依据
   输入：ods_* 主数据集表（营销漏斗两张表在模块7再做专项检查）
   输出：只读查询，不修改任何表
   运行：在项目根目录登录 mysql 后执行
         tee docs/dq_results.txt
         SOURCE sql/00_data_quality_checks.sql
         notee
   环境：MySQL 26.7（兼容 MySQL 8.0 及以上）
   作者：LeeMichael-L    日期：2026-10-11
   结构：
     A 完整性    缺失值
     B 唯一性    主键是否唯一、重复记录
     C 参照完整性 表之间能否关联上
     D 逻辑一致性 状态与时间戳、金额是否自洽
     E 口径相关分布 影响后续分析口径的分布特征
   每个检查以 check_id 标识，便于在审计报告中引用
   ===================================================================== */

USE olist;

/* ---------------------------------------------------------------------
   A 完整性
   --------------------------------------------------------------------- */

-- A1 订单表各时间戳缺失数，按订单状态拆分
--    预期：已送达订单应有全部时间戳；取消、未发货等状态可合理缺失
SELECT 'A1' AS check_id,
       order_status,
       COUNT(*)                                       AS orders,
       SUM(order_approved_at IS NULL)                 AS miss_approved,
       SUM(order_delivered_carrier_date IS NULL)      AS miss_carrier,
       SUM(order_delivered_customer_date IS NULL)     AS miss_delivered
FROM ods_orders
GROUP BY order_status
ORDER BY orders DESC;

-- A2 商品表字段缺失
SELECT 'A2' AS check_id,
       COUNT(*)                                   AS products,
       SUM(product_category_name IS NULL)         AS miss_category,
       SUM(product_photos_qty IS NULL)            AS miss_photos,
       SUM(product_weight_g IS NULL)              AS miss_weight,
       SUM(product_weight_g = 0)                  AS zero_weight
FROM ods_products;

-- A3 评论文本缺失（文本缺失是正常的：买家可以只打分不写评论）
SELECT 'A3' AS check_id,
       COUNT(*)                                   AS reviews,
       SUM(review_comment_title IS NULL)          AS miss_title,
       SUM(review_comment_message IS NULL)        AS miss_message,
       ROUND(AVG(review_comment_message IS NOT NULL) * 100, 1) AS pct_with_message
FROM ods_order_reviews;

/* ---------------------------------------------------------------------
   B 唯一性
   --------------------------------------------------------------------- */

-- B1 各表业务主键是否唯一：dup_keys = 总行数 − 去重后键数
SELECT 'B1' AS check_id, 'ods_orders.order_id' AS key_name,
       COUNT(*) AS row_cnt, COUNT(*) - COUNT(DISTINCT order_id) AS dup_keys
FROM ods_orders
UNION ALL
SELECT 'B1', 'ods_customers.customer_id',
       COUNT(*), COUNT(*) - COUNT(DISTINCT customer_id)
FROM ods_customers
UNION ALL
SELECT 'B1', 'ods_order_items.(order_id, order_item_id)',
       COUNT(*), COUNT(*) - COUNT(DISTINCT order_id, order_item_id)
FROM ods_order_items
UNION ALL
SELECT 'B1', 'ods_order_payments.(order_id, payment_sequential)',
       COUNT(*), COUNT(*) - COUNT(DISTINCT order_id, payment_sequential)
FROM ods_order_payments
UNION ALL
SELECT 'B1', 'ods_products.product_id',
       COUNT(*), COUNT(*) - COUNT(DISTINCT product_id)
FROM ods_products
UNION ALL
SELECT 'B1', 'ods_sellers.seller_id',
       COUNT(*), COUNT(*) - COUNT(DISTINCT seller_id)
FROM ods_sellers
UNION ALL
SELECT 'B1', 'ods_order_reviews.review_id',
       COUNT(*), COUNT(*) - COUNT(DISTINCT review_id)
FROM ods_order_reviews
UNION ALL
SELECT 'B1', 'ods_order_reviews.(review_id, order_id)',
       COUNT(*), COUNT(*) - COUNT(DISTINCT review_id, order_id)
FROM ods_order_reviews;

-- B2 评论与订单的对应关系
--    一单多评：同一订单有几条评论；一评多单：同一 review_id 挂在几个订单上
WITH per_order AS (
    SELECT order_id, COUNT(*) AS n_reviews
    FROM ods_order_reviews
    GROUP BY order_id
),
per_review AS (
    SELECT review_id, COUNT(DISTINCT order_id) AS n_orders
    FROM ods_order_reviews
    GROUP BY review_id
)
SELECT 'B2' AS check_id, 'reviews_per_order' AS dimension, n_reviews AS n, COUNT(*) AS cnt
FROM per_order GROUP BY n_reviews
UNION ALL
SELECT 'B2', 'orders_per_review_id', n_orders, COUNT(*)
FROM per_review GROUP BY n_orders
ORDER BY dimension, n;

-- B3 一单多评时，多条评论的分数是否一致（决定去重规则）
WITH multi AS (
    SELECT order_id,
           COUNT(*)                     AS n_reviews,
           COUNT(DISTINCT review_score) AS n_scores
    FROM ods_order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
)
SELECT 'B3' AS check_id,
       COUNT(*)                AS orders_with_multi_reviews,
       SUM(n_scores = 1)       AS same_score,
       SUM(n_scores > 1)       AS different_scores
FROM multi;

-- B4 地理表：每个邮编前缀对应多少组经纬度（决定 DWD 层如何取代表坐标）
WITH per_zip AS (
    SELECT geolocation_zip_code_prefix, COUNT(*) AS n_points
    FROM ods_geolocation
    GROUP BY geolocation_zip_code_prefix
)
SELECT 'B4' AS check_id,
       COUNT(*)                     AS zip_prefixes,
       SUM(n_points = 1)            AS single_point,
       MAX(n_points)                AS max_points,
       ROUND(AVG(n_points), 1)      AS avg_points
FROM per_zip;

-- B5 同一买家（customer_unique_id）对应多少个 customer_id
--    说明 customer_id 不能当作买家 ID 使用
WITH per_buyer AS (
    SELECT customer_unique_id, COUNT(DISTINCT customer_id) AS n_ids
    FROM ods_customers
    GROUP BY customer_unique_id
)
SELECT 'B5' AS check_id,
       COUNT(*)              AS unique_buyers,
       SUM(n_ids = 1)        AS buyers_with_1_id,
       SUM(n_ids > 1)        AS buyers_with_multi_ids,
       (SELECT COUNT(*) FROM ods_customers) AS customer_id_rows
FROM per_buyer;

/* ---------------------------------------------------------------------
   C 参照完整性
   --------------------------------------------------------------------- */

-- C1 子表中关联不到父表的记录数（孤儿记录），应全部为 0
SELECT 'C1' AS check_id, 'items → orders' AS relation, COUNT(*) AS orphans
FROM ods_order_items i LEFT JOIN ods_orders o ON i.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'C1', 'items → products', COUNT(*)
FROM ods_order_items i LEFT JOIN ods_products p ON i.product_id = p.product_id
WHERE p.product_id IS NULL
UNION ALL
SELECT 'C1', 'items → sellers', COUNT(*)
FROM ods_order_items i LEFT JOIN ods_sellers s ON i.seller_id = s.seller_id
WHERE s.seller_id IS NULL
UNION ALL
SELECT 'C1', 'orders → customers', COUNT(*)
FROM ods_orders o LEFT JOIN ods_customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL
UNION ALL
SELECT 'C1', 'payments → orders', COUNT(*)
FROM ods_order_payments p LEFT JOIN ods_orders o ON p.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'C1', 'reviews → orders', COUNT(*)
FROM ods_order_reviews r LEFT JOIN ods_orders o ON r.order_id = o.order_id
WHERE o.order_id IS NULL;

-- C2 父表中缺少子记录的订单：没有商品、没有支付、没有评论，按状态拆分
SELECT 'C2' AS check_id,
       o.order_status,
       COUNT(*)                                                           AS orders,
       SUM(NOT EXISTS (SELECT 1 FROM ods_order_items i    WHERE i.order_id = o.order_id)) AS no_items,
       SUM(NOT EXISTS (SELECT 1 FROM ods_order_payments p WHERE p.order_id = o.order_id)) AS no_payment,
       SUM(NOT EXISTS (SELECT 1 FROM ods_order_reviews r  WHERE r.order_id = o.order_id)) AS no_review
FROM ods_orders o
GROUP BY o.order_status
ORDER BY orders DESC;

-- C3 品类没有英文翻译的情况
SELECT 'C3' AS check_id,
       p.product_category_name,
       COUNT(*) AS products
FROM ods_products p
LEFT JOIN ods_category_translation t ON p.product_category_name = t.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND t.product_category_name IS NULL
GROUP BY p.product_category_name;

-- C4 买家、卖家邮编在地理表中查不到的比例（影响模块3的距离计算）
SELECT 'C4' AS check_id, 'customers' AS side,
       COUNT(*) AS cnt,
       SUM(NOT EXISTS (SELECT 1 FROM ods_geolocation g
                       WHERE g.geolocation_zip_code_prefix = c.customer_zip_code_prefix)) AS zip_not_found
FROM ods_customers c
UNION ALL
SELECT 'C4', 'sellers',
       COUNT(*),
       SUM(NOT EXISTS (SELECT 1 FROM ods_geolocation g
                       WHERE g.geolocation_zip_code_prefix = s.seller_zip_code_prefix))
FROM ods_sellers s;

/* ---------------------------------------------------------------------
   D 逻辑一致性
   --------------------------------------------------------------------- */

-- D1 时间戳先后顺序违规（只看有值的记录）
--    正常顺序：下单 ≤ 审核 ≤ 交物流 ≤ 送达
SELECT 'D1' AS check_id, 'approved < purchase' AS rule_broken,
       SUM(order_approved_at < order_purchase_timestamp) AS violations
FROM ods_orders
UNION ALL
SELECT 'D1', 'carrier < purchase',
       SUM(order_delivered_carrier_date < order_purchase_timestamp)
FROM ods_orders
UNION ALL
SELECT 'D1', 'carrier < approved',
       SUM(order_delivered_carrier_date < order_approved_at)
FROM ods_orders
UNION ALL
SELECT 'D1', 'delivered < carrier',
       SUM(order_delivered_customer_date < order_delivered_carrier_date)
FROM ods_orders
UNION ALL
SELECT 'D1', 'delivered < purchase',
       SUM(order_delivered_customer_date < order_purchase_timestamp)
FROM ods_orders
UNION ALL
SELECT 'D1', 'estimated < purchase',
       SUM(order_estimated_delivery_date < order_purchase_timestamp)
FROM ods_orders;

-- D2 "交物流早于审核"的违规幅度：区分时区/录入误差（小时级）与真实错误（天级）
SELECT 'D2' AS check_id,
       CASE
           WHEN TIMESTAMPDIFF(HOUR, order_delivered_carrier_date, order_approved_at) < 24  THEN '1: <1 day'
           WHEN TIMESTAMPDIFF(HOUR, order_delivered_carrier_date, order_approved_at) < 168 THEN '2: 1-7 days'
           ELSE '3: >7 days'
       END AS gap_bucket,
       COUNT(*) AS orders
FROM ods_orders
WHERE order_delivered_carrier_date < order_approved_at
GROUP BY gap_bucket
ORDER BY gap_bucket;

-- D3 订单状态与时间戳矛盾
SELECT 'D3' AS check_id, 'delivered but no delivery date' AS contradiction,
       COUNT(*) AS orders
FROM ods_orders
WHERE order_status = 'delivered' AND order_delivered_customer_date IS NULL
UNION ALL
SELECT 'D3', 'not delivered but has delivery date', COUNT(*)
FROM ods_orders
WHERE order_status <> 'delivered' AND order_delivered_customer_date IS NOT NULL;

-- D4 支付总额与商品金额 + 运费是否一致（容差 1 雷亚尔）
WITH item_total AS (
    SELECT order_id, SUM(price + freight_value) AS items_value
    FROM ods_order_items
    GROUP BY order_id
),
pay_total AS (
    SELECT order_id, SUM(payment_value) AS paid_value
    FROM ods_order_payments
    GROUP BY order_id
)
SELECT 'D4' AS check_id,
       CASE
           WHEN ABS(p.paid_value - i.items_value) <= 1 THEN '1: match (±1)'
           WHEN p.paid_value > i.items_value           THEN '2: paid more'
           ELSE                                             '3: paid less'
       END AS result,
       COUNT(*)                                          AS orders,
       ROUND(AVG(p.paid_value - i.items_value), 2)       AS avg_diff_brl
FROM item_total i
JOIN pay_total p ON i.order_id = p.order_id
GROUP BY result
ORDER BY result;

-- D5 金额异常值
SELECT 'D5' AS check_id,
       SUM(price <= 0)                 AS nonpositive_price,
       SUM(freight_value = 0)          AS zero_freight,
       MIN(price)                      AS min_price,
       MAX(price)                      AS max_price,
       MAX(freight_value)              AS max_freight,
       SUM(freight_value > price)      AS freight_gt_price
FROM ods_order_items;

-- D6 支付记录异常
SELECT 'D6' AS check_id,
       payment_type,
       COUNT(*)                        AS records,
       SUM(payment_value = 0)          AS zero_value,
       SUM(payment_installments = 0)   AS zero_installments,
       MAX(payment_installments)       AS max_installments
FROM ods_order_payments
GROUP BY payment_type
ORDER BY records DESC;

-- D7 评论问卷时间早于送达（买家没收到货就被邀请评价）
SELECT 'D7' AS check_id,
       SUM(r.review_answer_timestamp < r.review_creation_date)       AS answer_before_creation,
       SUM(r.review_creation_date < DATE(o.order_delivered_customer_date)) AS review_before_delivery,
       COUNT(*)                                                       AS reviews_on_delivered_orders
FROM ods_order_reviews r
JOIN ods_orders o ON r.order_id = o.order_id
WHERE o.order_delivered_customer_date IS NOT NULL;

/* ---------------------------------------------------------------------
   E 口径相关分布
   --------------------------------------------------------------------- */

-- E1 月度订单量：确定分析窗口（首尾稀疏月份要剔除）
SELECT 'E1' AS check_id,
       DATE_FORMAT(order_purchase_timestamp, '%Y-%m') AS purchase_month,
       COUNT(*)                                       AS orders,
       SUM(order_status = 'delivered')                AS delivered,
       SUM(order_status = 'canceled')                 AS canceled
FROM ods_orders
GROUP BY purchase_month
ORDER BY purchase_month;

-- E2 订单状态分布
SELECT 'E2' AS check_id,
       order_status,
       COUNT(*)                                           AS orders,
       ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 2)   AS pct
FROM ods_orders
GROUP BY order_status
ORDER BY orders DESC;

-- E3 一单多卖家、一单多件的占比（影响模块3、6的评分归属）
WITH per_order AS (
    SELECT order_id,
           COUNT(*)                   AS n_items,
           COUNT(DISTINCT seller_id)  AS n_sellers,
           COUNT(DISTINCT product_id) AS n_products
    FROM ods_order_items
    GROUP BY order_id
)
SELECT 'E3' AS check_id,
       COUNT(*)                                          AS orders_with_items,
       SUM(n_sellers > 1)                                AS multi_seller_orders,
       ROUND(AVG(n_sellers > 1) * 100, 2)                AS pct_multi_seller,
       SUM(n_items > 1)                                  AS multi_item_orders,
       ROUND(AVG(n_items > 1) * 100, 2)                  AS pct_multi_item,
       SUM(n_items > 1 AND n_products = 1)               AS same_product_qty_gt1
FROM per_order;

-- E4 买家下单次数分布（customer_unique_id 口径，复购率的预检查）
WITH per_buyer AS (
    SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS n_orders
    FROM ods_orders o
    JOIN ods_customers c ON o.customer_id = c.customer_id
    GROUP BY c.customer_unique_id
)
SELECT 'E4' AS check_id,
       CASE WHEN n_orders >= 4 THEN '4+' ELSE CAST(n_orders AS CHAR) END AS orders_per_buyer,
       COUNT(*)                                                         AS buyers,
       ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 2)                 AS pct
FROM per_buyer
GROUP BY orders_per_buyer
ORDER BY orders_per_buyer;

-- E5 评分分布
SELECT 'E5' AS check_id,
       review_score,
       COUNT(*)                                          AS reviews,
       ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 2)  AS pct
FROM ods_order_reviews
GROUP BY review_score
ORDER BY review_score;

-- E6 三种金额口径的总量对比（D-004 选择商品金额作为规模指标）
SELECT 'E6' AS check_id,
       (SELECT ROUND(SUM(price), 0)                 FROM ods_order_items)    AS items_price_brl,
       (SELECT ROUND(SUM(freight_value), 0)         FROM ods_order_items)    AS freight_brl,
       (SELECT ROUND(SUM(price + freight_value), 0) FROM ods_order_items)    AS price_plus_freight_brl,
       (SELECT ROUND(SUM(payment_value), 0)         FROM ods_order_payments) AS paid_brl;