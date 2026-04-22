-- Profit is split globally across stakeholders based on the ratio active at the time of each order.
-- profit_splits rows are matched by date range (effective_from / effective_to).
SELECT
  DATE_TRUNC('month', o.order_date)                                          AS month,
  s.name                                                                     AS stakeholder,
  SUM(oi.quantity * (oi.unit_price - p.procurement_price) * ps.ratio)        AS stakeholder_profit
FROM order_items oi
JOIN orders o          ON oi.order_id    = o.id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products p        ON pv.product_id  = p.id
JOIN profit_splits ps  ON o.order_date >= ps.effective_from
                      AND (ps.effective_to IS NULL OR o.order_date <= ps.effective_to)
JOIN stakeholders s    ON ps.stakeholder_id = s.id
WHERE o.status = 'picked_up'
GROUP BY DATE_TRUNC('month', o.order_date), s.name
ORDER BY month, stakeholder;
