# 数据字典

> 版本：v2（2026-10-16，阶段2结束）。第 1~3 节描述原始数据（ODS 层），第 4 节描述清洗与建模后的派生表（DWD / DWS / ADS 层）。原始数据的主键与关联关系已在阶段1 数据质量审计中验证，见第 3 节。

![ER图](er_diagram.png)

## 1. 表概览

两个数据集共11张表，按用途分为四组。

| 分组 | 表名 | 一行代表什么（粒度） | 主键 | 关联 | 记录数 |
| --- | --- | --- | --- | --- | ---: |
| 订单核心 | olist_orders_dataset | 一笔订单 | order_id | customer_id → customers | 99,441 |
| 订单核心 | olist_order_items_dataset | 订单里的**一件**商品（买2件 = 2行） | order_id + order_item_id | order_id → orders；product_id → products；seller_id → sellers | 112,650 |
| 订单核心 | olist_order_payments_dataset | 一笔订单的一条支付记录 | order_id + payment_sequential | order_id → orders | 103,886 |
| 订单核心 | olist_order_reviews_dataset | 一条满意度评价 | 无可靠主键（review_id 不唯一，见第 3 节） | order_id → orders | 99,224 |
| 参与者 | olist_customers_dataset | 一笔订单对应的买家身份 | customer_id | customer_zip_code_prefix → geolocation | 99,441 |
| 参与者 | olist_sellers_dataset | 一个卖家 | seller_id | seller_zip_code_prefix → geolocation | 3,095 |
| 参与者 | olist_products_dataset | 一个商品 | product_id | product_category_name → translation | 32,951 |
| 参考 | product_category_name_translation | 一个品类 | product_category_name | — | 71 |
| 参考 | olist_geolocation_dataset | 某个邮编前缀下的一个坐标点 | 无（邮编前缀可重复） | 被 customers、sellers 通过邮编前缀关联 | 1,000,163 |
| 营销漏斗 | olist_marketing_qualified_leads_dataset | 一条营销合格线索（一个潜在卖家） | mql_id | — | 8,000 |
| 营销漏斗 | olist_closed_deals_dataset | 一条签约成功的线索 | mql_id | mql_id → leads；seller_id → sellers | 842 |

记录数指数据行数（不含表头）。用"数文件行数"的方法得到的数字会比记录数大，因为部分评论正文内含换行符（3,852 条评论共 5,495 个换行符）。

## 2. 各表的关键字段

### orders 订单
订单的五个时间戳串起了履约全过程，是模块3的核心：

| 字段 | 含义 |
| --- | --- |
| order_purchase_timestamp | 下单时间 |
| order_approved_at | 支付审核通过时间 |
| order_delivered_carrier_date | 卖家把货交给物流的时间 |
| order_delivered_customer_date | 买家实际收货时间 |
| order_estimated_delivery_date | 下单时向买家承诺的送达日期 |
| order_status | 订单状态：delivered、shipped、canceled 等 |

### order_items 订单商品
| 字段 | 含义 |
| --- | --- |
| order_item_id | 订单内商品序号，从1开始。没有"数量"字段，同一商品买几件就有几行 |
| shipping_limit_date | 卖家必须把货交给物流的截止时间，用于判断卖家是否发货超时 |
| price | 这一件商品的价格（雷亚尔） |
| freight_value | 分摊到这一件商品的运费 |

### customers 客户
| 字段 | 含义 |
| --- | --- |
| customer_id | **每笔订单生成一个新ID**，同一个人下两单会有两个 customer_id |
| customer_unique_id | 识别真实买家的ID。计算买家数、复购率必须用它 |

### order_reviews 评价
| 字段 | 含义 |
| --- | --- |
| review_score | 1–5分 |
| review_creation_date | 系统向买家发送满意度问卷的日期 |
| review_answer_timestamp | 买家回答问卷的时间 |

### closed_deals 签约
| 字段 | 含义 |
| --- | --- |
| won_date | 签约时间 |
| business_segment | 卖家所属行业 |
| lead_type | 线索类型 |

### marketing_qualified_leads 线索
| 字段 | 含义 |
| --- | --- |
| first_contact_date | 首次接触日期 |
| origin | 获客渠道，例如自然搜索、付费搜索、社交媒体 |

## 3. 原始数据的验证结果

阶段1 数据质量审计（`sql/00_data_quality_checks.sql`，结果见 `docs/dq_results.txt`）对以下问题逐一检查：

| 问题 | 结果 | 处理 |
| --- | --- | --- |
| 评价表的 review_id 是否唯一？一笔订单是否可能有多条评价？ | 不唯一：789 个 review_id 挂在多个订单上（同一买家同时下单、共用一份问卷）；547 个订单有多条评价 | DWD 层改为每单一行，保留最后作答的一条（D-013） |
| 一笔订单是否可能包含多个卖家的商品？ | 是，1,278 单（1.3%） | 体验类指标只用单卖家订单（D-017、D-029） |
| 客户表、卖家表的邮编前缀能否都在地理表中找到？ | 客户 278 个、卖家 7 个邮编找不到；另有 42 个坐标点落在巴西境外 | 坐标记为 NULL；求平均前剔除境外坐标（D-019、D-027） |
| 订单的时间戳先后顺序是否都合理？ | 1,382 单存在时间顺序违规，多数相差不到 1 天 | 保留并标记，负的环节时长记为 NULL（D-014、D-026） |

## 4. 派生表（DWD / DWS / ADS 层）

建表脚本按层存放在 `sql/02_dwd/`、`sql/03_dws/`、`sql/04_ads/`。每个脚本末尾附有核对查询。

### 4.1 DWD 明细层：清洗与打标记，不删数据

脚本：`sql/02_dwd/01_create_dwd_tables.sql`

| 表 | 粒度 | 主键 | 行数 | 主要处理 |
| --- | --- | --- | ---: | --- |
| dwd_geo_zip | 一个邮编前缀 | zip_code_prefix | 19,010 | 每个邮编取境内坐标平均值（D-019、D-027） |
| dwd_customers | 一个 customer_id | customer_id | 99,441 | 关联邮编坐标 |
| dwd_sellers | 一个卖家 | seller_id | 3,095 | 关联邮编坐标 |
| dwd_products | 一个商品 | product_id | 32,951 | 补充品类英文名，缺失品类记为 unknown（D-018） |
| dwd_orders | 一笔订单 | order_id | 99,441 | 关联真实买家 ID；加分析窗口、状态矛盾、时间戳异常、多卖家等标记（D-014 ~ D-017） |
| dwd_order_items | 订单中的一件商品 | order_id + order_item_id | 112,650 | 关联品类 |
| dwd_order_reviews | 一笔订单 | order_id | 98,673 | 多条评价保留最后作答的一条，另存首次评分（D-013）；标记问卷是否早于送达（D-021） |

### 4.2 DWS 汇总层：按分析主题建立的宽表

| 表 | 粒度 | 主键 | 行数 | 范围与用途 | 脚本 |
| --- | --- | --- | ---: | --- | --- |
| dws_order_fulfillment | 一笔有效已送达订单 | order_id | 96,203 | 履约各环节时长、延误、卖家发货超时、跨州、距离、评价；模块3、6、7 的基础（D-023 ~ D-026） | `03_dws/01_create_dws_order_fulfillment.sql` |
| dws_seller | 一个卖家 | seller_id | 2,945 | 在有效订单中有成交的卖家；规模指标含多卖家订单，体验指标只用单卖家订单（D-029） | `03_dws/02_create_dws_seller.sql` |
| dws_seller_funnel | 一条营销线索 | mql_id | 8,000 | 线索、签约与签约后 90 天的经营情况（D-031）。漏斗数据字段干净、量小，直接从 ODS 读取，未单独建 DWD 表 | `03_dws/03_create_dws_seller_funnel.sql` |

### 4.3 ADS 应用层：模块结果

| 文件 | 内容 |
| --- | --- |
| `04_ads/m1_monthly_kpi.sql` | 模块1 月度指标查询（买家数、订单数、交易额） |
| `04_ads/m5_repurchase.sql` | 模块5 复购率相关查询 |
| `04_ads/m6_seller_tier.sql` | 建立结果表 `ads_m6_seller_tier`（一行一个卖家，2,945 行）：两个健康指标、置信区间下限与分层结果（D-030） |