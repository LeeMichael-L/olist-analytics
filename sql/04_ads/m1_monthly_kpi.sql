/* =====================================================================
   文件：m1_monthly_kpi.sql
   模块：1 指标体系与趋势
   业务问题：交易额的增长来自买家数、人均订单数还是客单价？
   输出：每月一行：月份、买家数、订单数、商品交易额
   作者：LeeMichael-L    日期：2026-10-13
   ===================================================================== */

WITH valid_order AS(
  SELECT order_id, purchase_month, customer_unique_id
  FROM dwd_orders
  WHERE order_status = 'delivered' AND in_analysis_window = 1 AND is_status_conflict = 0
),
order_price AS (
  SELECT purchase_month, customer_unique_id, order_id, SUM(price) AS total_price_per_order
  FROM valid_order JOIN dwd_order_items USING(order_id)
  GROUP BY purchase_month, customer_unique_id, order_id
)
SELECT purchase_month, COUNT(DISTINCT customer_unique_id) AS buyers, COUNT(order_id) AS orders, SUM(total_price_per_order) AS gmv_brl
FROM order_price
GROUP BY purchase_month
ORDER BY purchase_month; 


