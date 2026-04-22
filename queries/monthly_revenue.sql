SELECT
  DATE_TRUNC('month', o.order_date) AS month,
  SUM(oi.quantity * oi.unit_price)                          AS revenue,
  SUM(oi.quantity * p.procurement_price)                    AS cost,
  SUM(oi.quantity * (oi.unit_price - p.procurement_price))  AS profit
FROM order_items oi
JOIN orders o          ON oi.order_id    = o.id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products p        ON pv.product_id  = p.id
WHERE o.status = 'picked_up'
GROUP BY DATE_TRUNC('month', o.order_date)
ORDER BY month;
