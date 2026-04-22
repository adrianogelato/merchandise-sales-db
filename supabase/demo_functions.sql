-- ============================================================
-- Demo Functions — Interactive Portfolio Page
-- SECURITY DEFINER functions callable by the anon role.
-- Run after schema.sql and rls_policies.sql.
-- ============================================================


-- ── demo_get_metadata() ──────────────────────────────────────
-- Returns table row counts and the current unprocessed order queue.
-- Used by the demo page to show live database state.

CREATE OR REPLACE FUNCTION demo_get_metadata()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_counts json;
  v_queue  json;
BEGIN
  SELECT json_build_object(
    'order_entry_pending', (SELECT COUNT(*) FROM order_entry
                            WHERE status = 'paid' AND processed = FALSE AND error_note IS NULL),
    'order_entry_failed',  (SELECT COUNT(*) FROM order_entry
                            WHERE processed = FALSE AND error_note IS NOT NULL),
    'customers',           (SELECT COUNT(*) FROM customers),
    'orders',              (SELECT COUNT(*) FROM orders),
    'order_items',         (SELECT COUNT(*) FROM order_items)
  ) INTO v_counts;

  SELECT COALESCE(json_agg(q ORDER BY q.paypal_reference, q.id), '[]'::json)
  INTO v_queue
  FROM (
    SELECT id, customer_name, insta_handle, paypal_reference,
           variant_id, quantity, unit_price, error_note
    FROM order_entry
    WHERE status = 'paid' AND processed = FALSE
  ) q;

  RETURN json_build_object('counts', v_counts, 'queue', v_queue);
END;
$$;

GRANT EXECUTE ON FUNCTION demo_get_metadata() TO anon;


-- ── demo_run_etl(limit_n) ────────────────────────────────────
-- Processes up to limit_n paypal_reference groups from order_entry
-- into the normalized schema. NULL = no limit.
-- Mirrors the logic in supabase/etl_supabase.py.

CREATE OR REPLACE FUNCTION demo_run_etl(limit_n int DEFAULT NULL)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- Storage cap: refuse ETL if orders would exceed this threshold.
  -- Prevents runaway inserts on the Supabase free tier.
  MAX_ORDERS CONSTANT int := 100;

  v_refs         text[];
  v_ref          text;
  v_row_ids      int[];
  v_handle       text;
  v_cust_name    text;
  v_order_date   date;
  v_entry_status order_status;
  v_customer_id  int;
  v_order_db_id  int;
  v_order_id     int;
  v_item         record;
  v_variant      record;
  v_processed    int := 0;
  v_failed       int := 0;
  v_errors       jsonb := '[]';
  v_errmsg       text;
BEGIN
  -- Storage guard
  IF (SELECT COUNT(*) FROM orders) >= MAX_ORDERS THEN
    RETURN json_build_object(
      'processed', 0,
      'failed',    0,
      'errors',    '[]'::json,
      'message',   'Storage cap reached (' || MAX_ORDERS || ' orders). Reset to seed state first.'
    );
  END IF;

  -- Collect distinct paypal_references, respecting optional limit
  SELECT array_agg(paypal_reference)
  INTO v_refs
  FROM (
    SELECT DISTINCT paypal_reference
    FROM order_entry
    WHERE status = 'paid' AND processed = FALSE
    ORDER BY paypal_reference
    LIMIT limit_n
  ) sub;

  IF v_refs IS NULL THEN
    RETURN json_build_object(
      'processed', 0,
      'failed',    0,
      'errors',    '[]'::json,
      'message',   'No unprocessed entries found.'
    );
  END IF;

  FOREACH v_ref IN ARRAY v_refs LOOP
    SELECT array_agg(id) INTO v_row_ids
    FROM order_entry
    WHERE paypal_reference = v_ref AND status = 'paid' AND processed = FALSE;

    BEGIN
      -- Validate and normalise insta_handle (strip leading @, lowercase)
      SELECT
        regexp_replace(lower(trim(insta_handle)), '^@+', ''),
        customer_name,
        order_date,
        status::order_status
      INTO v_handle, v_cust_name, v_order_date, v_entry_status
      FROM order_entry WHERE id = v_row_ids[1];

      IF v_handle IS NULL OR v_handle = '' THEN
        RAISE EXCEPTION 'insta_handle: must not be empty';
      END IF;
      IF NOT (v_handle ~ '^[a-z0-9_.]+$') THEN
        RAISE EXCEPTION 'insta_handle: invalid characters in ''%''', v_handle;
      END IF;

      -- Upsert customer
      INSERT INTO customers (customer_name, insta_handle)
      VALUES (v_cust_name, v_handle)
      ON CONFLICT (insta_handle) DO UPDATE SET insta_handle = EXCLUDED.insta_handle
      RETURNING id INTO v_customer_id;

      -- Next sequential business order_id
      SELECT COALESCE(MAX(order_id), 1000) + 1 INTO v_order_id FROM orders;

      -- Insert order
      INSERT INTO orders (order_id, customer_id, order_date, status, paypal_reference)
      VALUES (v_order_id, v_customer_id, v_order_date, v_entry_status, v_ref)
      RETURNING id INTO v_order_db_id;

      -- Process each line item
      FOR v_item IN
        SELECT id, variant_id, quantity, unit_price
        FROM order_entry
        WHERE id = ANY(v_row_ids)
        ORDER BY id
      LOOP
        -- Lock variant row for the duration of this group's transaction
        SELECT id, current_stock INTO v_variant
        FROM product_variants
        WHERE variant_id = v_item.variant_id
        FOR UPDATE;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'variant_id ''%'' not found in product_variants', v_item.variant_id;
        END IF;
        IF v_variant.current_stock < v_item.quantity THEN
          RAISE EXCEPTION 'variant ''%'': insufficient stock (have %, need %)',
            v_item.variant_id, v_variant.current_stock, v_item.quantity;
        END IF;

        UPDATE product_variants
        SET current_stock = current_stock - v_item.quantity
        WHERE id = v_variant.id;

        INSERT INTO order_items (order_id, variant_id, quantity, unit_price)
        VALUES (v_order_db_id, v_variant.id, v_item.quantity, v_item.unit_price);
      END LOOP;

      UPDATE order_entry SET processed = TRUE WHERE id = ANY(v_row_ids);
      v_processed := v_processed + 1;

    EXCEPTION WHEN OTHERS THEN
      -- Subtransaction rolled back; record failure in outer transaction
      v_errmsg := SQLERRM;
      UPDATE order_entry
      SET processed = FALSE, error_note = v_errmsg
      WHERE id = ANY(v_row_ids);
      v_failed := v_failed + 1;
      v_errors := v_errors || jsonb_build_object('ref', v_ref, 'error', v_errmsg);
    END;
  END LOOP;

  RETURN json_build_object(
    'processed', v_processed,
    'failed',    v_failed,
    'errors',    v_errors
  );
END;
$$;

GRANT EXECUTE ON FUNCTION demo_run_etl(int) TO anon;


-- ── demo_reset_to_seed() ─────────────────────────────────────
-- Truncates all tables and restores the anonymised sample dataset.
-- Mirrors seed.sql exactly.

CREATE OR REPLACE FUNCTION demo_reset_to_seed()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  TRUNCATE TABLE
    stakeholders, product_categories, products, product_variants,
    profit_splits, customers, orders, order_items, restock_log, order_entry
  RESTART IDENTITY CASCADE;

  INSERT INTO stakeholders (id, name, email) VALUES
    (1, 'Café Owner', 'owner@example.com'),
    (2, 'Artist',     'artist@example.com');

  INSERT INTO profit_splits (stakeholder_id, ratio, effective_from, effective_to) VALUES
    (1, 0.6000, '2024-01-01', NULL),
    (2, 0.4000, '2024-01-01', NULL);

  INSERT INTO product_categories (id, name) VALUES
    (1, 'Apparel'),
    (2, 'Accessories');

  INSERT INTO products (id, name, category_id, description, base_price, procurement_price) VALUES
    (1, 'Logo T-Shirt', 1, 'Unisex cotton tee with embroidered café logo', 32.00, 12.00),
    (2, 'Logo Hoodie',  1, 'Heavyweight pullover hoodie',                  58.00, 22.00),
    (3, 'Tote Bag',     2, 'Canvas tote bag, one size',                    18.00,  6.00);

  INSERT INTO product_variants (id, variant_id, product_id, size, current_stock) VALUES
    (1, 'tshirt-s', 1, 'S',    8),
    (2, 'tshirt-m', 1, 'M',   12),
    (3, 'tshirt-l', 1, 'L',    5),
    (4, 'hoodie-m', 2, 'M',    4),
    (5, 'hoodie-l', 2, 'L',    3),
    (6, 'tote',     3, NULL,  20);

  INSERT INTO customers (id, customer_name, insta_handle) VALUES
    (1, 'Alex M.',   'alex_merch'),
    (2, 'Sam K.',    'sam_k'),
    (3, 'Jordan P.', 'jordanp_'),
    (4, 'Riley T.',  'riley.t'),
    (5, 'Morgan B.', 'morgan_b'),
    (6, 'Casey W.',  'casey_w');

  INSERT INTO orders (id, order_id, customer_id, order_date, status, paypal_reference) VALUES
    (1, 1001, 1, '2024-03-05', 'picked_up', 'PP-2024-001'),
    (2, 1002, 2, '2024-03-12', 'picked_up', 'PP-2024-002'),
    (3, 1003, 3, '2024-04-02', 'picked_up', 'PP-2024-003'),
    (4, 1004, 4, '2024-04-10', 'picked_up', 'PP-2024-004'),
    (5, 1005, 5, '2024-04-18', 'picked_up', 'PP-2024-005'),
    (6, 1006, 6, '2024-05-03', 'picked_up', 'PP-2024-006');

  INSERT INTO order_items (order_id, variant_id, quantity, unit_price) VALUES
    (1, 2, 1, 32.00),
    (1, 6, 2, 18.00),
    (2, 4, 1, 58.00),
    (3, 1, 1, 32.00),
    (3, 5, 1, 58.00),
    (4, 3, 2, 32.00),
    (5, 6, 1, 18.00),
    (5, 2, 1, 32.00),
    (6, 4, 1, 58.00),
    (6, 6, 3, 18.00);

  INSERT INTO restock_log (variant_id, restocked_at, quantity_added, notes) VALUES
    (2, '2024-02-20', 20, 'Initial stock — first production run'),
    (4, '2024-04-15', 10, 'Restock after sell-out in April');

  INSERT INTO order_entry
    (customer_name, insta_handle, order_date, paypal_reference, variant_id, quantity, unit_price, status, processed)
  VALUES
    ('Nova K.',   '@Nova_K',     '2024-05-10', 'PP-2024-020', 'tshirt-m',  1, 32.00, 'paid', FALSE),
    ('Sam K.',    'SAM_K',       '2024-05-11', 'PP-2024-021', 'tote',      2, 18.00, 'paid', FALSE),
    ('Luca B.',   '@Luca_B',     '2024-05-14', 'PP-2024-022', 'tshirt-s',  1, 32.00, 'paid', FALSE),
    ('Luca B.',   '@Luca_B',     '2024-05-14', 'PP-2024-022', 'tote',      1, 18.00, 'paid', FALSE),
    ('Bad Input', 'bad handle!', '2024-05-15', 'PP-2024-030', 'tshirt-m',  1, 32.00, 'paid', FALSE),
    ('Felix K.',  'felix.k',     '2024-05-16', 'PP-2024-031', 'hoodie-xs', 1, 58.00, 'paid', FALSE);

  PERFORM setval('stakeholders_id_seq',       (SELECT MAX(id) FROM stakeholders));
  PERFORM setval('product_categories_id_seq', (SELECT MAX(id) FROM product_categories));
  PERFORM setval('products_id_seq',           (SELECT MAX(id) FROM products));
  PERFORM setval('product_variants_id_seq',   (SELECT MAX(id) FROM product_variants));
  PERFORM setval('customers_id_seq',          (SELECT MAX(id) FROM customers));
  PERFORM setval('orders_id_seq',             (SELECT MAX(id) FROM orders));
  PERFORM setval('order_items_id_seq',        (SELECT MAX(id) FROM order_items));
  PERFORM setval('restock_log_id_seq',        (SELECT MAX(id) FROM restock_log));

  RETURN json_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION demo_reset_to_seed() TO anon;


-- ── demo_add_order_entry(...) ─────────────────────────────────
-- Inserts a single row into the order_entry staging table.
-- Validates inputs before inserting; caps total order_entry rows at 50
-- to prevent abuse on the free tier.

CREATE OR REPLACE FUNCTION demo_add_order_entry(
  p_customer_name    text,
  p_insta_handle     text,
  p_order_date       date,
  p_paypal_reference text,
  p_variant_id       text,
  p_quantity         int,
  p_unit_price       numeric
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  MAX_ENTRIES CONSTANT int := 50;
  v_new_id int;
BEGIN
  -- Storage cap
  IF (SELECT COUNT(*) FROM order_entry) >= MAX_ENTRIES THEN
    RAISE EXCEPTION 'Order entry cap reached (% rows). Reset to seed state first.', MAX_ENTRIES;
  END IF;

  -- Required field checks
  IF trim(coalesce(p_insta_handle, ''))     = '' THEN RAISE EXCEPTION 'insta_handle is required'; END IF;
  IF trim(coalesce(p_paypal_reference, '')) = '' THEN RAISE EXCEPTION 'paypal_reference is required'; END IF;
  IF trim(coalesce(p_variant_id, ''))       = '' THEN RAISE EXCEPTION 'variant_id is required'; END IF;
  IF coalesce(p_quantity, 0) <= 0           THEN RAISE EXCEPTION 'quantity must be greater than 0'; END IF;
  IF coalesce(p_unit_price, -1) < 0         THEN RAISE EXCEPTION 'unit_price cannot be negative'; END IF;

  -- Variant must exist
  IF NOT EXISTS (SELECT 1 FROM product_variants WHERE variant_id = p_variant_id) THEN
    RAISE EXCEPTION 'variant_id ''%'' does not exist', p_variant_id;
  END IF;

  INSERT INTO order_entry (
    customer_name, insta_handle, order_date, paypal_reference,
    variant_id, quantity, unit_price, status, processed
  ) VALUES (
    p_customer_name,
    p_insta_handle,
    coalesce(p_order_date, current_date),
    p_paypal_reference,
    p_variant_id,
    p_quantity,
    p_unit_price,
    'paid',
    FALSE
  ) RETURNING id INTO v_new_id;

  RETURN json_build_object('id', v_new_id, 'ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION demo_add_order_entry(text, text, date, text, text, int, numeric) TO anon;


-- ── demo_get_monthly_revenue() ────────────────────────────────
-- Returns revenue, cost, and profit aggregated by month.
-- Mirrors queries/monthly_revenue.sql.

CREATE OR REPLACE FUNCTION demo_get_monthly_revenue()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows json;
BEGIN
  SELECT COALESCE(json_agg(r ORDER BY r.month), '[]'::json)
  INTO v_rows
  FROM (
    SELECT
      TO_CHAR(DATE_TRUNC('month', o.order_date), 'Mon YYYY') AS month,
      SUM(oi.quantity * oi.unit_price)                         AS revenue,
      SUM(oi.quantity * p.procurement_price)                   AS cost,
      SUM(oi.quantity * (oi.unit_price - p.procurement_price)) AS profit
    FROM order_items oi
    JOIN orders          o  ON oi.order_id   = o.id
    JOIN product_variants pv ON oi.variant_id = pv.id
    JOIN products         p  ON pv.product_id  = p.id
    WHERE o.status = 'paid'
    GROUP BY DATE_TRUNC('month', o.order_date)
    ORDER BY DATE_TRUNC('month', o.order_date)
  ) r;

  RETURN v_rows;
END;
$$;

GRANT EXECUTE ON FUNCTION demo_get_monthly_revenue() TO anon;
