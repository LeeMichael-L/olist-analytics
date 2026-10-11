/* =====================================================================
   文件：02_load_ods_data.sql
   阶段：S1 · ODS 原始数据层
   目的：把 data/raw/ 下11个 CSV 原样导入 ODS 表
   运行前提：
     1. 服务端允许本地文件导入（只需设置一次）：SET GLOBAL local_infile = 1;
     2. 在项目根目录启动客户端，并带上参数：
        mysql -u root -p --local-infile=1 --default-character-set=utf8mb4
        （下面的文件路径都是相对于项目根目录的）
   导入规则：
     1. FIELDS ... OPTIONALLY ENCLOSED BY '"'：字段可能被双引号包住，
        引号里的逗号、换行都属于字段内容，不会被当成分隔符
     2. ESCAPED BY ''：关闭反斜杠转义。MySQL 默认把 \ 当转义符，
        评论里以 \ 结尾的文本会把结束引号"转义"掉，导致两行被合并、
        静默少导入数据
     3. NULLIF(@v, '')：源文件里的空字段转为 NULL，
        否则空字符串写进 DATETIME 等类型会报错
     4. TRIM(TRAILING '\r' FROM @v)：部分文件是 Windows 换行（\r\n），
        按 \n 断行后，每行最后一个字段末尾会残留一个 \r，需要去掉。
        对所有表的最后一列统一处理，无论文件是哪种换行都能正确导入
     5. 先 TRUNCATE 再导入：脚本可以反复运行，不会重复插入
   作者：LeeMichael-L    日期：2026-10-11
   ===================================================================== */

USE olist;

/* ---------------- 主数据集 ---------------- */

TRUNCATE TABLE ods_orders;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_orders_dataset.csv'
INTO TABLE ods_orders
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES                                   -- 跳过表头
(order_id, customer_id, order_status, order_purchase_timestamp,
 @approved, @carrier, @delivered, @estimated)    -- @开头的是临时变量
SET order_approved_at             = NULLIF(@approved, ''),
    order_delivered_carrier_date  = NULLIF(@carrier, ''),
    order_delivered_customer_date = NULLIF(@delivered, ''),
    order_estimated_delivery_date = TRIM(TRAILING '\r' FROM @estimated);

TRUNCATE TABLE ods_order_items;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_order_items_dataset.csv'
INTO TABLE ods_order_items
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, @freight)
SET freight_value = TRIM(TRAILING '\r' FROM @freight);

TRUNCATE TABLE ods_order_payments;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_order_payments_dataset.csv'
INTO TABLE ods_order_payments
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, payment_sequential, payment_type, payment_installments, @value)
SET payment_value = TRIM(TRAILING '\r' FROM @value);

-- ods_row_id 是自增列，不在字段列表里，由数据库自动编号
TRUNCATE TABLE ods_order_reviews;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_order_reviews_dataset.csv'
INTO TABLE ods_order_reviews
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(review_id, order_id, review_score, @title, @message,
 review_creation_date, @answer)
SET review_comment_title    = NULLIF(@title, ''),
    review_comment_message  = NULLIF(@message, ''),
    review_answer_timestamp = TRIM(TRAILING '\r' FROM @answer);

TRUNCATE TABLE ods_customers;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_customers_dataset.csv'
INTO TABLE ods_customers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, customer_unique_id, customer_zip_code_prefix, customer_city, @state)
SET customer_state = TRIM(TRAILING '\r' FROM @state);

TRUNCATE TABLE ods_sellers;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_sellers_dataset.csv'
INTO TABLE ods_sellers
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(seller_id, seller_zip_code_prefix, seller_city, @state)
SET seller_state = TRIM(TRAILING '\r' FROM @state);

TRUNCATE TABLE ods_products;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_products_dataset.csv'
INTO TABLE ods_products
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_id, @cat, @name_len, @desc_len, @photos, @weight, @length, @height, @width)
SET product_category_name      = NULLIF(@cat, ''),
    product_name_lenght        = NULLIF(@name_len, ''),
    product_description_lenght = NULLIF(@desc_len, ''),
    product_photos_qty         = NULLIF(@photos, ''),
    product_weight_g           = NULLIF(@weight, ''),
    product_length_cm          = NULLIF(@length, ''),
    product_height_cm          = NULLIF(@height, ''),
    product_width_cm           = NULLIF(TRIM(TRAILING '\r' FROM @width), '');

TRUNCATE TABLE ods_category_translation;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/product_category_name_translation.csv'
INTO TABLE ods_category_translation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_category_name, @english)
SET product_category_name_english = TRIM(TRAILING '\r' FROM @english);

-- 地理表约100万行，导入需要一些时间
TRUNCATE TABLE ods_geolocation;
LOAD DATA LOCAL INFILE 'data/raw/Brazilian_eCommerce/olist_geolocation_dataset.csv'
INTO TABLE ods_geolocation
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(geolocation_zip_code_prefix, geolocation_lat, geolocation_lng,
 geolocation_city, @state)
SET geolocation_state = TRIM(TRAILING '\r' FROM @state);

/* ---------------- 营销漏斗数据集 ---------------- */

TRUNCATE TABLE ods_mql;
LOAD DATA LOCAL INFILE 'data/raw/Marketing_Funnel_by_Olist/olist_marketing_qualified_leads_dataset.csv'
INTO TABLE ods_mql
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(mql_id, first_contact_date, @landing, @origin)
SET landing_page_id = NULLIF(@landing, ''),
    origin          = NULLIF(TRIM(TRAILING '\r' FROM @origin), '');

TRUNCATE TABLE ods_closed_deals;
LOAD DATA LOCAL INFILE 'data/raw/Marketing_Funnel_by_Olist/olist_closed_deals_dataset.csv'
INTO TABLE ods_closed_deals
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY ''
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(mql_id, seller_id, @sdr, @sr, won_date, @segment, @lead_type, @profile,
 @has_company, @has_gtin, @stock, @btype, @catalog, @revenue)
SET sdr_id                        = NULLIF(@sdr, ''),
    sr_id                         = NULLIF(@sr, ''),
    business_segment              = NULLIF(@segment, ''),
    lead_type                     = NULLIF(@lead_type, ''),
    lead_behaviour_profile        = NULLIF(@profile, ''),
    has_company                   = NULLIF(@has_company, ''),
    has_gtin                      = NULLIF(@has_gtin, ''),
    average_stock                 = NULLIF(@stock, ''),
    business_type                 = NULLIF(@btype, ''),
    declared_product_catalog_size = NULLIF(@catalog, ''),
    declared_monthly_revenue      = NULLIF(TRIM(TRAILING '\r' FROM @revenue), '');

/* ---------------- 导入核对 ---------------- */

-- 与源文件对比：expected_rows = 文件行数 − 1（表头）；评价表除外，原因见步骤1.5
SELECT 'ods_orders' AS table_name, COUNT(*) AS row_cnt, 99441 AS expected_rows FROM ods_orders
UNION ALL SELECT 'ods_order_items',          COUNT(*), 112650  FROM ods_order_items
UNION ALL SELECT 'ods_order_payments',       COUNT(*), 103886  FROM ods_order_payments
UNION ALL SELECT 'ods_order_reviews',        COUNT(*), NULL    FROM ods_order_reviews
UNION ALL SELECT 'ods_customers',            COUNT(*), 99441   FROM ods_customers
UNION ALL SELECT 'ods_sellers',              COUNT(*), 3095    FROM ods_sellers
UNION ALL SELECT 'ods_products',             COUNT(*), 32951   FROM ods_products
UNION ALL SELECT 'ods_category_translation', COUNT(*), 71      FROM ods_category_translation
UNION ALL SELECT 'ods_geolocation',          COUNT(*), 1000163 FROM ods_geolocation
UNION ALL SELECT 'ods_mql',                  COUNT(*), 8000    FROM ods_mql
UNION ALL SELECT 'ods_closed_deals',         COUNT(*), 842     FROM ods_closed_deals;