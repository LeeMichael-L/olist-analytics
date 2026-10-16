/* =====================================================================
   文件：sql/04_ads/m6_seller_tier.sql
   用途：模块6 卖家分层结果表 ads_m6_seller_tier（一行 = 一个卖家）
   分层规则（D-030）：
     - 两个健康度指标（都是卖家可控的）：
         体验：未延误订单的差评率（排除物流影响）
         时效：发货超时率
     - 样本门槛：未延误且有评价的订单 < 30 单 → "样本不足"
     - 规模：GMV 排名前 20% → 头部，其余 → 腰部
     - 问题判定：指标的 95% 置信区间下限 > 平台平均（统计上可以确定比平均差）
     - 问题类型：两项都正常 → 健康；只有时效差 → 时效问题；只有体验差 → 体验问题；都差 → 双重问题
   依赖：dws_seller、dws_order_fulfillment
   作者：LeeMichael-L    日期：2026-10-15
   ===================================================================== */

USE olist;

DROP TABLE IF EXISTS ads_m6_seller_tier;
CREATE TABLE ads_m6_seller_tier (
    seller_id             CHAR(32)      NOT NULL,
    seller_state          CHAR(2)       NOT NULL,
    main_category         VARCHAR(64)   NOT NULL,
    gmv                   DECIMAL(12,2) NOT NULL,
    gmv_rank              INT           NOT NULL,
    n_orders              INT           NOT NULL,
    -- 体验：未延误订单差评率
    n_ot_reviewed         INT           NOT NULL,  -- 未延误且有评价的单卖家订单数
    n_ot_bad              INT           NOT NULL,
    ot_bad_rate           DECIMAL(6,4)  NULL,
    ot_bad_lower          DECIMAL(6,4)  NULL,      -- 95% 置信区间下限
    platform_ot_bad       DECIMAL(6,4)  NOT NULL,  -- 平台基准
    -- 时效：发货超时率
    n_ship_orders         INT           NOT NULL,  -- is_seller_late 非 NULL 的单卖家订单数
    n_seller_late         INT           NOT NULL,
    seller_late_rate      DECIMAL(6,4)  NULL,
    seller_late_lower     DECIMAL(6,4)  NULL,
    platform_seller_late  DECIMAL(6,4)  NOT NULL,
    -- 分层结果
    is_head               TINYINT       NOT NULL,  -- GMV 前 20%
    problem_type          VARCHAR(10)   NULL,      -- 健康/时效问题/体验问题/双重问题；样本不足为 NULL
    tier                  VARCHAR(12)   NOT NULL,  -- 规模-问题类型，或"样本不足"
    PRIMARY KEY (seller_id),
    INDEX idx_ads_tier (tier)
) COMMENT = 'ADS 模块6 卖家分层';   -- 不单独指定字符集，沿用数据库默认（utf8mb4_unicode_ci），与其他表保持一致

INSERT INTO ads_m6_seller_tier
WITH per_seller AS (
    -- 只有单卖家订单的 seller_id 有值（D-029）
    SELECT seller_id,
           SUM(CASE WHEN is_late = 0 THEN has_review    ELSE 0 END) AS n_ot_reviewed,
           SUM(CASE WHEN is_late = 0 THEN is_bad_review ELSE 0 END) AS n_ot_bad,
           COUNT(is_seller_late)                                    AS n_ship_orders,
           COALESCE(SUM(is_seller_late), 0)                         AS n_seller_late
    FROM dws_order_fulfillment
    WHERE seller_id IS NOT NULL
    GROUP BY seller_id
),
base AS (
    -- 平台基准：全部单卖家订单
    SELECT SUM(CASE WHEN is_late = 0 THEN is_bad_review END)
             / SUM(CASE WHEN is_late = 0 THEN has_review END) AS p0,
           SUM(is_seller_late) / COUNT(is_seller_late)        AS q0
    FROM dws_order_fulfillment
    WHERE seller_id IS NOT NULL
),
s AS (
    SELECT d.seller_id, d.seller_state, d.main_category, d.gmv, d.n_orders,
           COALESCE(o.n_ot_reviewed, 0) AS n_ot_reviewed,
           COALESCE(o.n_ot_bad, 0)      AS n_ot_bad,
           COALESCE(o.n_ship_orders, 0) AS n_ship_orders,
           COALESCE(o.n_seller_late, 0) AS n_seller_late,
           o.n_ot_bad      / NULLIF(o.n_ot_reviewed, 0) AS p,
           o.n_seller_late / NULLIF(o.n_ship_orders, 0) AS q,
           ROW_NUMBER() OVER (ORDER BY d.gmv DESC, d.seller_id) AS gmv_rank,
           COUNT(*)     OVER ()                                 AS n_sellers
    FROM dws_seller d
    LEFT JOIN per_seller o ON d.seller_id = o.seller_id
),
s2 AS (
    -- 置信区间下限：比率 − 1.96 × √(比率 × (1 − 比率) / 样本量)
    SELECT s.*, b.p0, b.q0,
           p - 1.96 * SQRT(p * (1 - p) / NULLIF(n_ot_reviewed, 0)) AS p_lower,
           q - 1.96 * SQRT(q * (1 - q) / NULLIF(n_ship_orders, 0)) AS q_lower,
           (gmv_rank <= 0.2 * n_sellers)                          AS is_head
    FROM s
    CROSS JOIN base b
),
s3 AS (
    SELECT s2.*,
           CASE
               WHEN n_ot_reviewed < 30             THEN NULL
               WHEN p_lower > p0 AND q_lower > q0  THEN '双重问题'
               WHEN p_lower > p0                   THEN '体验问题'
               WHEN q_lower > q0                   THEN '时效问题'
               ELSE                                     '健康'
           END AS problem_type
    FROM s2
)
SELECT seller_id, seller_state, main_category, gmv, gmv_rank, n_orders,
       n_ot_reviewed, n_ot_bad, ROUND(p, 4), ROUND(p_lower, 4), ROUND(p0, 4),
       n_ship_orders, n_seller_late, ROUND(q, 4), ROUND(q_lower, 4), ROUND(q0, 4),
       is_head,
       problem_type,
       CASE WHEN problem_type IS NULL THEN '样本不足'
            ELSE CONCAT(IF(is_head = 1, '头部', '腰部'), '-', problem_type)
       END
FROM s3;

/* ---------------------------------------------------------------------
   核对与汇总
   --------------------------------------------------------------------- */
-- 1. 行数应为 2,945；两个基准约为 0.0871 和 0.0899
SELECT COUNT(*)                  AS sellers,
       MAX(platform_ot_bad)      AS p0_ot_bad,
       MAX(platform_seller_late) AS q0_seller_late
FROM ads_m6_seller_tier;

-- 2. 各层汇总（先合并个数再相除，不对卖家的比率直接求平均）
SELECT tier,
       COUNT(*)                                                         AS sellers,
       ROUND(SUM(gmv) / (SELECT SUM(gmv) FROM ads_m6_seller_tier), 4)  AS gmv_share,
       ROUND(SUM(n_ot_bad) / SUM(n_ot_reviewed), 4)                    AS ot_bad_rate,
       ROUND(SUM(n_seller_late) / SUM(n_ship_orders), 4)               AS seller_late_rate
FROM ads_m6_seller_tier
GROUP BY tier
ORDER BY FIELD(tier, '头部-健康', '头部-时效问题', '头部-体验问题', '头部-双重问题',
                     '腰部-健康', '腰部-时效问题', '腰部-体验问题', '腰部-双重问题', '样本不足');