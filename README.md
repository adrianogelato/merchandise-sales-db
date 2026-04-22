# Merchandise Sales Database

A merchandise tracking system for a café, built to manage stock, record sales, and calculate revenue and profit splits between stakeholders. The sales workflow is fully manual: customers order via Instagram DM, pay via PayPal, and pick up in-store.

The system has two implementations:
- **SeaTable** — the live operational tool
- **Supabase / PostgreSQL** — a portfolio artifact with full DDL, seed data, and RLS policies

---

## Live Demo

The Supabase database is publicly readable for product and stock data. No authentication needed.

**Link to demo page:** https://adrianogelato.github.io/merchandise-sales-db/

**Browse products:**
```bash

curl 'https://cjrfexiwugazxosmzxwl.supabase.co/rest/v1/products?select=name,base_price,procurement_price' \
  -H "apikey: sb_publishable_5adWOFHHNQa33Jz6DsqWzQ_AZ2rTYoB" \
  -H "Accept: application/json"
```

**Current stock per variant:**
```bash
curl 'https://cjrfexiwugazxosmzxwl.supabase.co/rest/v1/product_variants?select=size,current_stock,products(name)' \
  -H "apikey: sb_publishable_5adWOFHHNQa33Jz6DsqWzQ_AZ2rTYoB" \
  -H "Accept: application/json"
```

---

## Repository Structure

```
├── .github/
│   └── workflows/
│       └── etl.yml                     # GitHub Actions: scheduled ETL run
├── schema.sql                          # Shared PostgreSQL DDL
├── seatable/
│   └── etl_seatable.py                 # ETL: SeaTable → normalized schema
├── queries/
│   ├── monthly_revenue.sql             # Revenue, cost, and profit by month
│   ├── monthly_stakeholder_split.sql   # Per-stakeholder profit by month
│   └── current_stock_overview.sql      # Current stock per variant
└── supabase/
    ├── etl_supabase.py                 # ETL: order_entry → normalized schema
    ├── seed.sql                        # Anonymized sample data + ETL test rows
    └── rls_policies.sql                # Row Level Security policies
```

---

## Schema

The schema is split into three layers: reference data, transactional data, and a staging layer for data entry.

### Reference tables

| Table | Purpose |
|---|---|
| `stakeholders` | The people sharing profits from sales |
| `product_categories` | Groupings for products (e.g. apparel, accessories) |
| `products` | Core product records with `base_price` and `procurement_price` |
| `product_variants` | One row per size/variant per product; tracks `current_stock`. Size is NULL for non-apparel items |
| `profit_splits` | Rules defining how revenue is divided between stakeholders, with temporal validity |

### Transactional tables

| Table | Purpose |
|---|---|
| `customers` | Deduplicated by `insta_handle` (Instagram username is the customer identity) |
| `orders` | One row per order, linked to a customer. Status: `pending → paid → picked_up` |
| `order_items` | Line items per order. `unit_price` is snapshotted at time of sale |
| `restock_log` | Records stock replenishment events per variant |

### Staging table

| Table | Purpose |
|---|---|
| `order_entry` | A flat, form-friendly input table. Rows sharing the same `paypal_reference` belong to the same multi-item order |

### ERD (simplified)

```
stakeholders ──< profit_splits

product_categories ──< products ──< product_variants ──< order_items >── orders >── customers
                                          │
                                      restock_log

order_entry  ──(ETL)──> orders + order_items
```

---

## Supabase Setup

### 1. Deploy the schema

In the Supabase SQL editor, run `schema.sql`. This creates all tables, indexes, and the `order_status` enum.

### 2. Load sample data

Run `supabase/seed.sql` to populate the database with anonymized sample data covering all tables. Safe to run on a fresh database only.

The seed file includes a set of unprocessed `order_entry` rows specifically designed to exercise the ETL's data cleaning logic:

| PayPal ref | Input issue | Expected ETL outcome |
|---|---|---|
| `PP-2024-020` | `insta_handle` has `@` prefix | Succeeds — `@` stripped, new customer created |
| `PP-2024-021` | `insta_handle` is uppercase | Succeeds — lowercased, matched to existing customer |
| `PP-2024-022` | Multi-item order, uppercase + `@` prefix | Succeeds — both items processed, new customer created |
| `PP-2024-030` | `insta_handle` contains space and `!` | Fails — rejected by handle validation, `error_note` written |
| `PP-2024-031` | `variant_id` does not exist | Fails — lookup error, `error_note` written |

### 3. Apply RLS policies

Run `supabase/rls_policies.sql` to enable Row Level Security. Three access tiers are defined:

| Role | Access |
|---|---|
| `anon` | Read-only: `product_categories`, `products`, `product_variants` |
| `authenticated` | Read: `customers`, `orders`, `order_items` |
| `service_role` | Full access to all tables (bypasses RLS by default) |

### 4. Connect the ETL

Copy `.env.example` to `.env` at the repo root and fill in your Supabase connection string (find it under **Project Settings → Database → Connection string → URI**):

```
DATABASE_URL=postgresql://postgres:[your-password]@[your-project-ref].supabase.co:5432/postgres
```

Then install dependencies and run:

```bash
pip install psycopg2-binary python-dotenv
python "supabase/etl_supabase.py"
```

`.env` is listed in `.gitignore` and will never be committed. For GitHub Actions, the same variable is read from the `DATABASE_URL` Actions secret instead.

This step is done to verify the ETL script works as intended before relying on the automated workflow.

---

## GitHub Actions

The workflow at `.github/workflows/etl.yml` runs the Supabase ETL automatically every night at 23:00 UTC, and can also be triggered manually from the Actions tab.

### Setup

1. In your GitHub repository, go to **Settings → Secrets and variables → Actions**
2. Add a secret named `DATABASE_URL` with your Supabase connection string

The workflow checks out the repo, installs `psycopg2-binary`, and runs `etl_supabase.py`. Output from each run (including any `error_note` entries) is visible in the Actions log.

---

## ETL Logic

Two ETL scripts share the same logic and data cleaning pipeline. They differ only in how they connect to the database:

| Script | Target | How to run |
|---|---|---|
| `seatable/etl_seatable.py` | SeaTable (production) | Run inside SeaTable's Python runner |
| `supabase/etl_supabase.py` | Supabase / PostgreSQL | Run locally or via GitHub Actions |

Both scripts bridge the `order_entry` staging table into the normalized schema and are designed to be debuggable, with verbose `print` statements at each step.

### Steps

1. **Fetch unprocessed rows** from `order_entry` where the status is `paid` and `processed = FALSE`
2. **Group by `paypal_reference`** to reconstruct multi-item orders from flat staging rows
3. **Upsert customer** by `insta_handle` — creates a new record only if one doesn't already exist
4. **Generate `order_id`** sequentially (SeaTable has no native auto-increment)
5. **Insert into `orders`**, then into **`order_items`** for each line item, writing the current price as `unit_price`
6. **Decrement `current_stock`** on the relevant `product_variant`
7. **Mark rows as processed**, or flag with an `error_note` if something fails

---

## Design Decisions

### Background

I was asked to support a friend's café merchandise sales. The products are advertised via Instagram posts. The planned workflow for the order handling is via Instagram direct messages (dm). People can dm the business account and order the product. Payment is handled via the business PayPal account. Item pickup is done in-store. Hence, delivery tracking is not necessary. Stock tracking is done manually by the owner based on the sales. 

For easy integration into the café's daily operation and for traceability of the orders I wanted a workflow that can be easily understood by and explained to my friend, and eventually others if the merchandise setup needs to be transferred or scaled.

At the current stage the setup is a test run and working well. The manual effort with Instagram dms and the staging layer works for handling approx. 50 sales per week. Scaling will be done depending on how much merchandise items are sold. Currently.

### Why the two implementations with SeaTable and Supabase?

I wanted to setup a minimum viable product that works with little effort. I chose SeaTable as an alternative to AirTable, because I wanted to use a European service. SeaTable is used as the production environment that carries real-world data.

For my professional development and portfolio I wanted to setup the general logic and pipeline in a more widely used service. Supabase's free tier allowed sufficently many features. A European alternative like Nhost.io was limited to one project in the free tier which is too few for my plans.

### `order_entry` table as a staging layer
Data entry happens in a flat, form-friendly table rather than directly into the normalized schema. This separates the UX of recording a sale from the relational structure needed for reporting. The ETL script bridges the two.

### `unit_price` snapshotted on `order_items`
Prices are written to `order_items` at the time of sale rather than being a live foreign key to the product. This ensures historical sales data stays accurate even if prices change later.

### Temporal profit splits
`profit_splits` rows carry `effective_from` and `effective_to` dates. The stakeholder split query joins on date range, so historical profit calculations remain accurate even if the split ratio changes over time.

### Order status as a single-select column
Order status (`pending`, `paid`, `picked_up`) lives as a single-select column on `orders` rather than a linked status table. SeaTable's single-select columns handle this naturally and the added complexity of a status table wasn't justified.

### `insta_handle` as the customer identity
Customers are deduplicated and identified by their Instagram handle, which matches the real-world order intake process (orders come in via Instagram DM).

### NULL size for non-apparel variants
`product_variants.size` is NULL for products that don't have size options. This avoids a separate table or a sentinel value, while keeping all variants in one place.

---

## SeaTable-Specific Notes

SeaTable has several quirks that affect how the ETL script is written.

**No native boolean** — use number columns with values `0` and `1` instead.

**Linked record fields return as lists of dicts** — e.g. `[{'row_id': '...', 'display_value': '...'}]`. The ETL script uses an `extract_linked_value` helper to unwrap these. Status fields were switched to single-select to avoid this entirely.

**Variant ID linked records return as plain strings** — unlike other linked fields, these return as `['some-id']` rather than a list of dicts. The `extract_linked_value` helper handles both forms by checking `isinstance(first, dict)`.

**Date fields are ISO 8601 with timezone offset** — parse with `datetime.fromisoformat()`.
