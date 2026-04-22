-- ============================================================
-- Row Level Security Policies — Merchandise Sales Database
-- Run after schema.sql.
--
-- Three access tiers:
--   Public (anon)     — read-only access to the product catalog
--   Authenticated     — read access to their own orders/customers
--   service_role      — full access to everything (bypasses RLS by default)
-- ============================================================


-- ── Enable RLS on all tables ──────────────────────────────────

ALTER TABLE stakeholders        ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_categories  ENABLE ROW LEVEL SECURITY;
ALTER TABLE products            ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_variants    ENABLE ROW LEVEL SECURITY;
ALTER TABLE profit_splits       ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders              ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items         ENABLE ROW LEVEL SECURITY;
ALTER TABLE restock_log         ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_entry         ENABLE ROW LEVEL SECURITY;


-- ── Tier 1: Public read — product catalog ─────────────────────
-- Anyone (including unauthenticated visitors) can browse products.
-- No write access is granted at this tier.

CREATE POLICY "Public can view product categories"
  ON product_categories FOR SELECT
  USING (true);

CREATE POLICY "Public can view products"
  ON products FOR SELECT
  USING (true);

CREATE POLICY "Public can view product variants"
  ON product_variants FOR SELECT
  USING (true);


-- ── Tier 2: Authenticated read — orders and customers ─────────
-- Signed-in users can read order and customer data.
-- Write operations go through the ETL / service layer only.

CREATE POLICY "Authenticated users can view customers"
  ON customers FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can view orders"
  ON orders FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "Authenticated users can view order items"
  ON order_items FOR SELECT
  TO authenticated
  USING (true);


-- ── Tier 3: service_role only — admin / financial tables ──────
-- profit_splits, stakeholders, restock_log, and order_entry hold
-- financial or operational data that should never be exposed via
-- the public API. service_role bypasses RLS by default in Supabase,
-- so no explicit policy is needed — the blanket ENABLE above is
-- sufficient to block anon and authenticated roles.
--
-- Tables restricted to service_role:
--   stakeholders, profit_splits, restock_log, order_entry
