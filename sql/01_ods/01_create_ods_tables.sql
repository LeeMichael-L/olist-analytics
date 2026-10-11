/* =====================================================================
   文件：01_create_ods_tables.sql
   阶段：S1 · ODS 原始数据层
   目的：创建 olist 数据库和11张 ODS 表
   原则：
     1. 原样落地：只定义字段类型，不清洗、不去重、不删行
     2. 不设业务主键：源数据如有重复，主键会导致导入失败或静默丢行，
        重复问题应由数据质量审计发现、在 DWD 层处理
     3. 评论表、地理表没有可靠的唯一键，加自增代理键 ods_row_id
     4. 在 ID 和关联字段上建普通索引，加快后续查询
   环境：MySQL 26.7（兼容 MySQL 8.0 及以上）
   作者：LeeMichael-L    日期：2026-10-11
   ===================================================================== */

-- 建库：utf8mb4 字符集能存储所有语言文字（评论是葡萄牙语）
CREATE DATABASE IF NOT EXISTS olist
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_unicode_ci;

USE olist;

/* ---------------- 订单核心 ---------------- */

-- 订单表：一行 = 一笔订单
DROP TABLE IF EXISTS ods_orders;   -- 先删再建，脚本可以反复运行
CREATE TABLE ods_orders (
    order_id                       CHAR(32)    NOT NULL,
    customer_id                    CHAR(32)    NOT NULL,
    order_status                   VARCHAR(20) NOT NULL,
    order_purchase_timestamp       DATETIME    NOT NULL,  -- 下单时间
    order_approved_at              DATETIME    NULL,      -- 审核时间
    order_delivered_carrier_date   DATETIME    NULL,      -- 交给物流时间
    order_delivered_customer_date  DATETIME    NULL,      -- 买家收货时间
    order_estimated_delivery_date  DATETIME    NOT NULL,  -- 承诺送达日期
    INDEX idx_orders_order (order_id),
    INDEX idx_orders_customer (customer_id)
) COMMENT = 'ODS 订单';

-- 订单商品表：一行 = 订单里的一件商品（同一商品买2件 = 2行）
DROP TABLE IF EXISTS ods_order_items;
CREATE TABLE ods_order_items (
    order_id             CHAR(32)      NOT NULL,
    order_item_id        SMALLINT      NOT NULL,  -- 订单内商品序号
    product_id           CHAR(32)      NOT NULL,
    seller_id            CHAR(32)      NOT NULL,
    shipping_limit_date  DATETIME      NOT NULL,  -- 卖家发货截止时间
    price                DECIMAL(10,2) NOT NULL,
    freight_value        DECIMAL(10,2) NOT NULL,  -- 分摊到这件商品的运费
    INDEX idx_items_order (order_id),
    INDEX idx_items_product (product_id),
    INDEX idx_items_seller (seller_id)
) COMMENT = 'ODS 订单商品';

-- 支付表：一行 = 一条支付记录（一笔订单可分多次支付）
DROP TABLE IF EXISTS ods_order_payments;
CREATE TABLE ods_order_payments (
    order_id              CHAR(32)      NOT NULL,
    payment_sequential    SMALLINT      NOT NULL,  -- 支付序号
    payment_type          VARCHAR(20)   NOT NULL,  -- credit_card、boleto 等
    payment_installments  SMALLINT      NOT NULL,  -- 分期期数
    payment_value         DECIMAL(10,2) NOT NULL,
    INDEX idx_pay_order (order_id)
) COMMENT = 'ODS 支付';

-- 评价表：一行 = 一条评价；review_id 不保证唯一，加自增代理键
DROP TABLE IF EXISTS ods_order_reviews;
CREATE TABLE ods_order_reviews (
    ods_row_id               INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    review_id                CHAR(32)     NOT NULL,
    order_id                 CHAR(32)     NOT NULL,
    review_score             TINYINT      NOT NULL,  -- 1-5分
    review_comment_title     VARCHAR(100) NULL,
    review_comment_message   TEXT         NULL,
    review_creation_date     DATETIME     NOT NULL,  -- 发送问卷日期
    review_answer_timestamp  DATETIME     NOT NULL,  -- 买家作答时间
    INDEX idx_rev_review (review_id),
    INDEX idx_rev_order (order_id)
) COMMENT = 'ODS 评价';

/* ---------------- 参与者 ---------------- */

-- 客户表：一行 = 一笔订单的买家身份；识别真实买家用 customer_unique_id
DROP TABLE IF EXISTS ods_customers;
CREATE TABLE ods_customers (
    customer_id               CHAR(32)    NOT NULL,
    customer_unique_id        CHAR(32)    NOT NULL,
    customer_zip_code_prefix  CHAR(5)     NOT NULL,  -- 邮编用字符，避免丢失前导零
    customer_city             VARCHAR(64) NOT NULL,
    customer_state            CHAR(2)     NOT NULL,
    INDEX idx_cust_id (customer_id),
    INDEX idx_cust_unique (customer_unique_id)
) COMMENT = 'ODS 客户';

-- 卖家表：一行 = 一个卖家
DROP TABLE IF EXISTS ods_sellers;
CREATE TABLE ods_sellers (
    seller_id               CHAR(32)    NOT NULL,
    seller_zip_code_prefix  CHAR(5)     NOT NULL,
    seller_city             VARCHAR(64) NOT NULL,
    seller_state            CHAR(2)     NOT NULL,
    INDEX idx_seller_id (seller_id)
) COMMENT = 'ODS 卖家';

-- 商品表：一行 = 一个商品；源文件字段名拼写为 lenght，ODS 层保留原拼写
DROP TABLE IF EXISTS ods_products;
CREATE TABLE ods_products (
    product_id                  CHAR(32)    NOT NULL,
    product_category_name       VARCHAR(64) NULL,
    product_name_lenght         SMALLINT    NULL,
    product_description_lenght  SMALLINT    NULL,
    product_photos_qty          SMALLINT    NULL,
    product_weight_g            INT         NULL,
    product_length_cm           SMALLINT    NULL,
    product_height_cm           SMALLINT    NULL,
    product_width_cm            SMALLINT    NULL,
    INDEX idx_prod_id (product_id),
    INDEX idx_prod_category (product_category_name)
) COMMENT = 'ODS 商品';

/* ---------------- 参考表 ---------------- */

-- 品类翻译表：一行 = 一个品类（葡萄牙语 → 英语）
DROP TABLE IF EXISTS ods_category_translation;
CREATE TABLE ods_category_translation (
    product_category_name          VARCHAR(64) NOT NULL,
    product_category_name_english  VARCHAR(64) NOT NULL,
    INDEX idx_trans_category (product_category_name)
) COMMENT = 'ODS 品类翻译';

-- 地理表：一行 = 某邮编前缀下的一个坐标点；邮编可重复，加自增代理键
DROP TABLE IF EXISTS ods_geolocation;
CREATE TABLE ods_geolocation (
    ods_row_id                   INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    geolocation_zip_code_prefix  CHAR(5)     NOT NULL,
    geolocation_lat              DOUBLE      NOT NULL,
    geolocation_lng              DOUBLE      NOT NULL,
    geolocation_city             VARCHAR(64) NOT NULL,
    geolocation_state            CHAR(2)     NOT NULL,
    INDEX idx_geo_zip (geolocation_zip_code_prefix)
) COMMENT = 'ODS 地理';

/* ---------------- 营销漏斗 ---------------- */

-- 线索表：一行 = 一条营销合格线索（一个潜在卖家）
DROP TABLE IF EXISTS ods_mql;
CREATE TABLE ods_mql (
    mql_id              CHAR(32)    NOT NULL,
    first_contact_date  DATE        NOT NULL,  -- 首次接触日期
    landing_page_id     CHAR(32)    NULL,
    origin              VARCHAR(32) NULL,      -- 获客渠道
    INDEX idx_mql_id (mql_id)
) COMMENT = 'ODS 营销合格线索';

-- 签约表：一行 = 一条签约成功的线索；通过 seller_id 连接主数据集
DROP TABLE IF EXISTS ods_closed_deals;
CREATE TABLE ods_closed_deals (
    mql_id                         CHAR(32)      NOT NULL,
    seller_id                      CHAR(32)      NOT NULL,
    sdr_id                         CHAR(32)      NULL,  -- 线索开发专员
    sr_id                          CHAR(32)      NULL,  -- 销售代表
    won_date                       DATETIME      NOT NULL,  -- 签约时间
    business_segment               VARCHAR(64)   NULL,  -- 卖家所属行业
    lead_type                      VARCHAR(32)   NULL,
    lead_behaviour_profile         VARCHAR(32)   NULL,
    has_company                    VARCHAR(8)    NULL,
    has_gtin                       VARCHAR(8)    NULL,
    average_stock                  VARCHAR(32)   NULL,
    business_type                  VARCHAR(32)   NULL,
    declared_product_catalog_size  DECIMAL(10,1) NULL,
    declared_monthly_revenue       DECIMAL(14,2) NULL,  -- 卖家自报月收入
    INDEX idx_deal_mql (mql_id),
    INDEX idx_deal_seller (seller_id)
) COMMENT = 'ODS 签约卖家';