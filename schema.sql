-- ============================================================
-- Merchandise Sales Database — Supabase / PostgreSQL DDL
-- ============================================================
--
-- RELATION MAP
-- ============
--
-- [stakeholders] ──< [profit_splits]
--   stakeholders.id  →  profit_splits.stakeholder_id   (one stakeholder, many split rules)
--
-- [product_categories] ──< [products] ──< [product_variants] ──< [order_items] >── [orders] >── [customers]
--   product_categories.id  →  products.category_id              (one category, many products)
--   products.id            →  product_variants.product_id       (one product, many size/variants)
--   product_variants.id    →  order_items.variant_id            (one variant, many line items)
--   orders.id              →  order_items.order_id              (one order, many line items)
--   customers.id           →  orders.customer_id                (one customer, many orders)
--
-- [product_variants] ──< [restock_log]
--   product_variants.id    →  restock_log.variant_id            (one variant, many restock events)
--
-- [order_entry] ──(ETL)──> [orders] + [order_items]
--   order_entry.insta_handle  resolves to / upserts  customers.insta_handle
--   order_entry.variant_id    resolves to            product_variants.variant_id  (text lookup, not FK)
--   order_entry rows sharing the same paypal_reference become one order + N order_items
--
-- ============================================================
-- Import order respects FK dependencies:
--   1. Types
--   2. Reference tables (no inbound FKs): stakeholders, product_categories, customers
--   3. Dependent reference tables:        products → product_categories
--                                         product_variants → products
--                                         profit_splits → stakeholders
--   4. Transactional tables:              orders → customers
--                                         order_items → orders, product_variants
--                                         restock_log → product_variants
--   5. Staging table:                     order_entry (no FKs by design)
-- ============================================================


-- ── Types ────────────────────────────────────────────────────

CREATE TYPE order_status AS ENUM ('pending', 'paid', 'picked_up');


-- ── Reference Tables ─────────────────────────────────────────

-- No inbound FKs — safe to create first.

CREATE TABLE stakeholders (
    id              SERIAL          PRIMARY KEY,
    name            TEXT            NOT NULL,
    email           TEXT            UNIQUE
    -- Referenced by: profit_splits.stakeholder_id
);

CREATE TABLE product_categories (
    id              SERIAL          PRIMARY KEY,
    name            TEXT            NOT NULL UNIQUE
    -- Referenced by: products.category_id
);

-- Customers are deduplicated by insta_handle (orders arrive via Instagram DM).
-- insta_handle is also the join key used by the ETL script to upsert customers
-- from order_entry rows before creating an order.
CREATE TABLE customers (
    id              SERIAL          PRIMARY KEY,
    customer_name   TEXT,
    insta_handle    TEXT            NOT NULL UNIQUE
    -- Referenced by: orders.customer_id
);

CREATE TABLE products (
    id                SERIAL          PRIMARY KEY,
    name              TEXT            NOT NULL,
    category_id       INT             NOT NULL REFERENCES product_categories (id),
    description       TEXT,
    base_price        NUMERIC(10, 2)  NOT NULL CHECK (base_price >= 0),
    procurement_price NUMERIC(10, 2)  NOT NULL DEFAULT 0 CHECK (procurement_price >= 0)
    -- Referenced by: product_variants.product_id
);

-- One row per size/variant per product.
-- size is NULL for non-apparel items (e.g. tote bags, stickers).
-- variant_id is the human-readable text identifier used in order_entry and the ETL;
-- it is not the PK but must be unique and is the resolution key for staging rows.
CREATE TABLE product_variants (
    id              SERIAL          PRIMARY KEY,
    variant_id      TEXT            NOT NULL UNIQUE,
    product_id      INT             NOT NULL REFERENCES products (id),
    size            TEXT,                              -- NULL for non-apparel
    current_stock   INT             NOT NULL DEFAULT 0 CHECK (current_stock >= 0)
    -- Referenced by: order_items.variant_id, restock_log.variant_id
    -- Resolved by:   order_entry.variant_id (text lookup via ETL)
);

-- Profit split rules. Ratios across all active rows (effective_to IS NULL)
-- should sum to 1. Temporal validity is tracked via effective_from / effective_to.
CREATE TABLE profit_splits (
    id              SERIAL          PRIMARY KEY,
    stakeholder_id  INT             NOT NULL REFERENCES stakeholders (id),
    ratio           NUMERIC(5, 4)   NOT NULL CHECK (ratio > 0 AND ratio <= 1),
    effective_from  DATE            NOT NULL,
    effective_to    DATE,                              -- NULL = currently active
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);


-- ── Transactional Tables ──────────────────────────────────────

CREATE TABLE orders (
    id               SERIAL          PRIMARY KEY,
    order_id         INT             NOT NULL UNIQUE,  -- sequential business-facing ID
    customer_id      INT             NOT NULL REFERENCES customers (id),
    order_date       DATE            NOT NULL,
    status           order_status    NOT NULL DEFAULT 'pending',
    paypal_reference TEXT            UNIQUE
    -- References:  customers.id  (many orders → one customer)
    -- Referenced by: order_items.order_id
);

-- unit_price is snapshotted at time of sale — not a live reference to products.base_price.
-- This ensures historical sales figures remain accurate if prices change later.
CREATE TABLE order_items (
    id              SERIAL          PRIMARY KEY,
    order_id        INT             NOT NULL REFERENCES orders (id),
    variant_id      INT             NOT NULL REFERENCES product_variants (id),
    quantity        INT             NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10, 2)  NOT NULL CHECK (unit_price >= 0)
    -- References: orders.id          (many items → one order)
    --             product_variants.id (many items → one variant)
);

CREATE TABLE restock_log (
    id              SERIAL          PRIMARY KEY,
    variant_id      INT             NOT NULL REFERENCES product_variants (id),
    restocked_at    DATE            NOT NULL DEFAULT CURRENT_DATE,
    quantity_added  INT             NOT NULL CHECK (quantity_added > 0),
    notes           TEXT
    -- References: product_variants.id (many restock events → one variant)
);


-- ── Staging Table ─────────────────────────────────────────────

-- Flat, form-friendly input table — no FK constraints by design.
-- The ETL script (etl_seatable.py) promotes rows where status = 'paid'
-- and processed = FALSE into the normalized schema:
--
--   insta_handle     → upsert into customers, resolve to customers.id
--   paypal_reference → groups rows into one order (one order per reference)
--   variant_id       → text lookup against product_variants.variant_id
--   quantity         → written to order_items.quantity
--   unit_price       → written to order_items.unit_price (snapshot)
--
-- On success: processed = TRUE
-- On failure: processed stays FALSE, error_note records the reason
CREATE TABLE order_entry (
    id               SERIAL          PRIMARY KEY,
    customer_name    TEXT,
    insta_handle     TEXT            NOT NULL,
    order_date       DATE            NOT NULL,
    paypal_reference TEXT            NOT NULL,
    variant_id       TEXT            NOT NULL,         -- resolves to product_variants.variant_id
    quantity         INT             NOT NULL CHECK (quantity > 0),
    unit_price       NUMERIC(10, 2)  NOT NULL CHECK (unit_price >= 0),
    status           TEXT            NOT NULL DEFAULT 'paid',
    processed        BOOLEAN         NOT NULL DEFAULT FALSE,
    error_note       TEXT,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);


-- ── Indexes ───────────────────────────────────────────────────

-- Orders are frequently queried by customer and by status
CREATE INDEX idx_orders_customer_id        ON orders (customer_id);
CREATE INDEX idx_orders_status             ON orders (status);

-- Order items are always fetched by order or variant
CREATE INDEX idx_order_items_order_id      ON order_items (order_id);
CREATE INDEX idx_order_items_variant_id    ON order_items (variant_id);

-- Stock look-ups on variants are keyed by human-readable variant_id
CREATE INDEX idx_product_variants_variant_id ON product_variants (variant_id);

-- Staging: ETL fetches by status + processed flag
CREATE INDEX idx_order_entry_unprocessed   ON order_entry (status, processed)
    WHERE processed = FALSE;
