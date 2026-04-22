SELECT
  p.name AS product_name,
  pv.size,
  pv.current_stock
FROM product_variants pv
JOIN products p ON pv.product_id = p.id
ORDER BY p.name, pv.size;
