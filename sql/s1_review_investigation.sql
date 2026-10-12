/* =====================================================================
   文件：s1_review_investigation.sql
   阶段：S1 · 数据质量审计 · 专项调查
   目的：解释评价表与订单表之间的"多对多"关系，为清洗规则 D-013 提供依据
   背景（来自审计 B1–B3）：
     - 789 个 review_id 挂在多个订单上
     - 547 个订单有多条评价，其中 202 个订单的评分不一致
   输入：ods_order_reviews、ods_orders、ods_customers
   结论汇总：
     - 假设1 成立：一个 review_id 对应多个订单，是同一买家同时下单、只收到一份问卷
     - 假设2 部分成立：多条评价多数来自不同日期发出的问卷（72%），
       但"后一次评分更高"不成立，评分在两个方向都有变化
     - 由于只影响约 0.2% 的订单，采用"保留最后作答的一条"（D-013）
   作者：LeeMichael-L    日期：2026-10-12
   ===================================================================== */

USE olist;

/* ---------------------------------------------------------------------
   查询1：一个 review_id 挂在多个订单上，原因是什么？
   假设1：同一买家同一时间下了多笔订单，系统只发了一份问卷
   若成立：这些订单属于同一买家、下单时间接近、评分完全相同
   结果：review_ids 789 | same_buyer 789 | ordered_within_1h 748 | same_score 789
   结论：假设1成立。全部属于同一买家、评分全部相同，95% 在1小时内下单
   --------------------------------------------------------------------- */
WITH multi AS (
    -- 找出挂在多个订单上的 review_id
    SELECT review_id
    FROM ods_order_reviews
    GROUP BY review_id
    HAVING COUNT(DISTINCT order_id) > 1
),
detail AS (
    -- 对每个这样的 review_id，计算它关联的订单有什么特征
    SELECT r.review_id,
           COUNT(DISTINCT c.customer_unique_id) AS n_buyers,
           TIMESTAMPDIFF(MINUTE, MIN(o.order_purchase_timestamp),
                                 MAX(o.order_purchase_timestamp)) AS span_minutes,
           COUNT(DISTINCT r.review_score) AS n_scores
    FROM ods_order_reviews r
    JOIN multi m         ON r.review_id = m.review_id
    JOIN ods_orders o    ON r.order_id = o.order_id
    JOIN ods_customers c ON o.customer_id = c.customer_id
    GROUP BY r.review_id
)
SELECT COUNT(*)                AS review_ids,
       SUM(n_buyers = 1)       AS same_buyer,          -- 属于同一买家
       SUM(span_minutes <= 60) AS ordered_within_1h,   -- 1小时内下单
       SUM(n_scores = 1)       AS same_score           -- 评分相同
FROM detail;


/* ---------------------------------------------------------------------
   查询2：一个订单有多条评价，原因是什么？
   假设2：系统在不同时间给同一订单发了多份问卷
   若成立：问卷发送日期不同，且部分订单第一份问卷早于送达
   结果：orders 547 | different_survey_dates 392 | avg_gap_days 5.2
         | first_survey_before_delivery 160
   结论：72% 的订单问卷发送日期不同，平均相隔 5.2 天，支持"多次发送"；
         但仍有 155 个订单的多条评价在同一天发出，假设只能解释大部分情况
   --------------------------------------------------------------------- */
WITH multi AS (
    -- 找出有多条评价的订单
    SELECT order_id
    FROM ods_order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
),
detail AS (
    SELECT r.order_id,
           COUNT(DISTINCT r.review_creation_date) AS n_survey_dates,
           DATEDIFF(MAX(r.review_creation_date),
                    MIN(r.review_creation_date)) AS gap_days,
           MIN(r.review_creation_date)           AS first_survey,
           MAX(o.order_delivered_customer_date)  AS delivered_at
    FROM ods_order_reviews r
    JOIN multi m      ON r.order_id = m.order_id
    JOIN ods_orders o ON r.order_id = o.order_id
    GROUP BY r.order_id
)
SELECT COUNT(*)                                    AS orders,
       SUM(n_survey_dates > 1)                     AS different_survey_dates,
       ROUND(AVG(gap_days), 1)                     AS avg_gap_days,
       SUM(first_survey < DATE(delivered_at))      AS first_survey_before_delivery
FROM detail;


/* ---------------------------------------------------------------------
   查询3：同一订单的多条评价，是否属于同一个买家？
   结果：orders 547 | with_different_unique_id 0
   结论：全部属于同一买家。该结果由数据结构决定：一笔订单只有一个
         customer_id，因此其评价只能指向同一买家
   教训：第一版查询把 order_id 与 customer_id 连接，结果 orders = 0，
         没有报错但查询为空。拿到结果须先与已知数字（547）核对
   --------------------------------------------------------------------- */
WITH multi AS (
    SELECT order_id
    FROM ods_order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
),
detail AS (
    SELECT r.order_id,
           COUNT(DISTINCT u.customer_unique_id) AS different_user
    FROM ods_order_reviews r
    JOIN multi m         ON r.order_id = m.order_id
    JOIN ods_orders o    ON r.order_id = o.order_id
    JOIN ods_customers u ON o.customer_id = u.customer_id
    GROUP BY r.order_id
)
SELECT COUNT(*)                                   AS orders,
       SUM(CASE WHEN different_user > 1 THEN 1
                ELSE 0 END)                       AS with_different_unique_id
FROM detail;


/* ---------------------------------------------------------------------
   查询4：同一订单首尾两次评分如何变化？
   假设：若后一份问卷在收货后发出，最后一次评分应普遍更高
   排序依据：review_answer_timestamp（精确到秒）；
            review_creation_date 只精确到日期，review_id 是随机字符，均不适合排序
   结果：orders 547 | avg_dif -0.15 | last_smaller 113 | same 346 | last_bigger 88
   结论：假设不成立。最后一次评分更低的订单多于更高的，平均下降 0.15 分
   交叉验证：last_smaller + last_bigger = 201，与审计 B3 的 202 相差1个订单
            （该订单有3条以上评价，首尾分数相同、中间不同）
   敏感性：改用 review_creation_date 排序时为 120 / 345 / 82，平均 -0.20，结论不变
   --------------------------------------------------------------------- */
WITH multi AS (
    SELECT order_id
    FROM ods_order_reviews
    GROUP BY order_id
    HAVING COUNT(review_id) > 1
),
review_rank AS (
    -- 每个订单内按作答时间正序、倒序各编一次号
    SELECT order_id,
           review_score,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp, review_id)           AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC, review_id DESC) AS rn_last
    FROM ods_order_reviews
    JOIN multi USING (order_id)
),
dif AS (
    -- 条件聚合：把每个订单的首尾评分取到同一行，计算差值
    SELECT order_id,
           MAX(CASE WHEN rn_last = 1  THEN review_score END)
         - MAX(CASE WHEN rn_first = 1 THEN review_score END) AS dif
    FROM review_rank
    GROUP BY order_id
)
SELECT COUNT(*)                                  AS orders,
       AVG(dif)                                  AS avg_dif,
       MAX(dif)                                  AS max_dif,
       MIN(dif)                                  AS min_dif,
       SUM(CASE WHEN dif < 0 THEN 1 ELSE 0 END)  AS last_smaller,
       SUM(CASE WHEN dif = 0 THEN 1 ELSE 0 END)  AS same,
       SUM(CASE WHEN dif > 0 THEN 1 ELSE 0 END)  AS last_bigger
FROM dif;


/* ---------------------------------------------------------------------
   查询5：按"第一份问卷是否早于送达"分组，直接检验假设
   若假设成立：早于送达的一组，评分应明显上升
   结果：
     first_before = 0：397 单，平均 -0.15（下降 77 / 不变 260 / 上升 60）
     first_before = 1：150 单，平均 -0.14（下降 36 / 不变 86 / 上升 28）
   结论：即使第一份问卷早于送达，最后一次评分平均仍是下降，假设被否定
   --------------------------------------------------------------------- */
WITH multi AS (
    SELECT order_id
    FROM ods_order_reviews
    GROUP BY order_id
    HAVING COUNT(*) > 1
),
review_rank AS (
    SELECT r.order_id,
           r.review_score,
           r.review_creation_date,
           o.order_delivered_customer_date                                         AS delivered_at,
           ROW_NUMBER() OVER (PARTITION BY r.order_id
                              ORDER BY r.review_answer_timestamp, r.review_id)           AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY r.order_id
                              ORDER BY r.review_answer_timestamp DESC, r.review_id DESC) AS rn_last
    FROM ods_order_reviews r
    JOIN multi USING (order_id)
    JOIN ods_orders o USING (order_id)
),
dif AS (
    SELECT order_id,
           MAX(CASE WHEN rn_last = 1  THEN review_score END)
         - MAX(CASE WHEN rn_first = 1 THEN review_score END)                AS dif,
           -- 第一份问卷是否早于送达：是 = 1，否 = 0
           MAX(CASE WHEN rn_first = 1
                     AND review_creation_date < DATE(delivered_at)
                    THEN 1 ELSE 0 END)                                       AS first_before
    FROM review_rank
    GROUP BY order_id
)
SELECT first_before,
       COUNT(*)            AS orders,
       ROUND(AVG(dif), 2)  AS avg_dif,
       SUM(dif < 0)        AS last_smaller,
       SUM(dif = 0)        AS same,
       SUM(dif > 0)        AS last_bigger
FROM dif
GROUP BY first_before;