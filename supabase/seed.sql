-- ============================================================
-- Seed Data — Merchandise Sales Database
-- Anonymized sample data for local development and portfolio demos.
-- Run after schema.sql. Safe to re-run on an empty database only.
-- ============================================================


-- ── Stakeholders ──────────────────────────────────────────────

INSERT INTO stakeholders (id, name, email) VALUES
  (1, 'Café Owner',  'owner@example.com'),
  (2, 'Artist',      'artist@example.com');


-- ── Profit Splits ─────────────────────────────────────────────

-- 60 % to Café Owner, 40 % to Artist, active from 2024-01-01
INSERT INTO profit_splits (stakeholder_id, ratio, effective_from, effective_to) VALUES
  (1, 0.6000, '2024-01-01', NULL),
  (2, 0.4000, '2024-01-01', NULL);


-- ── Product Categories ────────────────────────────────────────

INSERT INTO product_categories (id, name) VALUES
  (1, 'Apparel'),
  (2, 'Accessories');


-- ── Products ──────────────────────────────────────────────────

INSERT INTO products (id, name, category_id, description, base_price, procurement_price) VALUES
  (1, 'Logo T-Shirt',  1, 'Unisex cotton tee with embroidered café logo', 32.00, 12.00),
  (2, 'Logo Hoodie',   1, 'Heavyweight pullover hoodie',                  58.00, 22.00),
  (3, 'Tote Bag',      2, 'Canvas tote bag, one size',                    18.00,  6.00);


-- ── Product Variants ──────────────────────────────────────────

INSERT INTO product_variants (id, variant_id, product_id, size, current_stock) VALUES
  (1, 'tshirt-s',  1, 'S',   8),
  (2, 'tshirt-m',  1, 'M',  12),
  (3, 'tshirt-l',  1, 'L',   5),
  (4, 'hoodie-m',  2, 'M',   4),
  (5, 'hoodie-l',  2, 'L',   3),
  (6, 'tote',      3, NULL, 20);


-- ── Customers ─────────────────────────────────────────────────
-- These represent customers whose orders have already been processed
-- into the normalized schema (orders + order_items below).

INSERT INTO customers (id, customer_name, insta_handle) VALUES
  (1, 'Alex M.',    'alex_merch'),
  (2, 'Sam K.',     'sam_k'),
  (3, 'Jordan P.',  'jordanp_'),
  (4, 'Riley T.',   'riley.t'),
  (5, 'Morgan B.',  'morgan_b'),
  (6, 'Casey W.',   'casey_w');


-- ── Orders ────────────────────────────────────────────────────

INSERT INTO orders (id, order_id, customer_id, order_date, status, paypal_reference) VALUES
  (1, 1001, 1, '2024-03-05', 'picked_up', 'PP-2024-001'),
  (2, 1002, 2, '2024-03-12', 'picked_up', 'PP-2024-002'),
  (3, 1003, 3, '2024-04-02', 'picked_up', 'PP-2024-003'),
  (4, 1004, 4, '2024-04-10', 'picked_up', 'PP-2024-004'),
  (5, 1005, 5, '2024-04-18', 'picked_up', 'PP-2024-005'),
  (6, 1006, 6, '2024-05-03', 'picked_up', 'PP-2024-006');


-- ── Order Items ───────────────────────────────────────────────

INSERT INTO order_items (order_id, variant_id, quantity, unit_price) VALUES
  (1, 2, 1, 32.00),   -- Alex:   1 × T-Shirt M
  (1, 6, 2, 18.00),   -- Alex:   2 × Tote Bag
  (2, 4, 1, 58.00),   -- Sam:    1 × Hoodie M
  (3, 1, 1, 32.00),   -- Jordan: 1 × T-Shirt S
  (3, 5, 1, 58.00),   -- Jordan: 1 × Hoodie L
  (4, 3, 2, 32.00),   -- Riley:  2 × T-Shirt L
  (5, 6, 1, 18.00),   -- Morgan: 1 × Tote Bag
  (5, 2, 1, 32.00),   -- Morgan: 1 × T-Shirt M
  (6, 4, 1, 58.00),   -- Casey:  1 × Hoodie M
  (6, 6, 3, 18.00);   -- Casey:  3 × Tote Bag


-- ── Restock Log ───────────────────────────────────────────────

INSERT INTO restock_log (variant_id, restocked_at, quantity_added, notes) VALUES
  (2, '2024-02-20', 20, 'Initial stock — first production run'),
  (4, '2024-04-15', 10, 'Restock after sell-out in April');


-- ── order_entry — ETL test rows ───────────────────────────────
--
-- These unprocessed rows (processed = FALSE) are used to exercise
-- the ETL script. They cover both normalizable input and cases that
-- should fail validation. See README for the expected outcome of each.
--
-- Groups that should SUCCEED (ETL normalizes the input):
--
--   PP-2024-020  insta_handle has @ prefix → stripped to 'nova_k'       (new customer)
--   PP-2024-021  insta_handle is uppercase  → lowercased to 'sam_k'     (existing customer)
--   PP-2024-022  multi-item order, handle has uppercase + @ prefix       (new customer)
--
-- Groups that should FAIL (ETL writes error_note, row stays unprocessed):
--
--   PP-2024-030  insta_handle contains a space and special char → rejected by regex
--   PP-2024-031  variant_id does not exist in product_variants   → lookup fails
--
-- ── Normalizable: @ prefix on handle ─────────────────────────
INSERT INTO order_entry
  (customer_name, insta_handle, order_date, paypal_reference, variant_id, quantity, unit_price, status, processed)
VALUES
  ('Nova K.',  '@Nova_K',  '2024-05-10', 'PP-2024-020', 'tshirt-m', 1, 32.00, 'paid', FALSE);

-- ── Normalizable: uppercase handle resolves to existing customer ──
INSERT INTO order_entry
  (customer_name, insta_handle, order_date, paypal_reference, variant_id, quantity, unit_price, status, processed)
VALUES
  ('Sam K.',  'SAM_K',  '2024-05-11', 'PP-2024-021', 'tote', 2, 18.00, 'paid', FALSE);

-- ── Normalizable: multi-item order, uppercase + @ prefix ─────
INSERT INTO order_entry
  (customer_name, insta_handle, order_date, paypal_reference, variant_id, quantity, unit_price, status, processed)
VALUES
  ('Luca B.',  '@Luca_B',  '2024-05-14', 'PP-2024-022', 'tshirt-s',  1, 32.00, 'paid', FALSE),
  ('Luca B.',  '@Luca_B',  '2024-05-14', 'PP-2024-022', 'tote',      1, 18.00, 'paid', FALSE);

-- ── Should fail: handle contains space and invalid character ──
INSERT INTO order_entry
  (customer_name, insta_handle, order_date, paypal_reference, variant_id, quantity, unit_price, status, processed)
VALUES
  ('Bad Input',  'bad handle!',  '2024-05-15', 'PP-2024-030', 'tshirt-m', 1, 32.00, 'paid', FALSE);

-- ── Should fail: variant_id does not exist ────────────────────
INSERT INTO order_entry
  (customer_name, insta_handle, order_date, paypal_reference, variant_id, quantity, unit_price, status, processed)
VALUES
  ('Felix K.',  'felix.k',  '2024-05-16', 'PP-2024-031', 'hoodie-xs', 1, 58.00, 'paid', FALSE);


-- ── Sequence resets (avoids PK collisions on future inserts) ──

SELECT setval('stakeholders_id_seq',      (SELECT MAX(id) FROM stakeholders));
SELECT setval('product_categories_id_seq',(SELECT MAX(id) FROM product_categories));
SELECT setval('products_id_seq',          (SELECT MAX(id) FROM products));
SELECT setval('product_variants_id_seq',  (SELECT MAX(id) FROM product_variants));
SELECT setval('customers_id_seq',         (SELECT MAX(id) FROM customers));
SELECT setval('orders_id_seq',            (SELECT MAX(id) FROM orders));
SELECT setval('order_items_id_seq',       (SELECT MAX(id) FROM order_items));
SELECT setval('restock_log_id_seq',       (SELECT MAX(id) FROM restock_log));
