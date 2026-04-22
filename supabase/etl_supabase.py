"""
ETL: order_entry staging table → normalized schema (Supabase / PostgreSQL).

Reads unprocessed rows from order_entry (status='paid', processed=FALSE),
groups them by paypal_reference to reconstruct multi-item orders, then
inserts into customers, orders, order_items, and decrements stock.

Usage (local):
    1. Copy .env.example to .env and fill in DATABASE_URL.
    2. pip install psycopg2-binary python-dotenv
    3. python etl_supabase.py

Usage (GitHub Actions):
    DATABASE_URL is read from the DATABASE_URL Actions secret — no .env needed.

Requires:
    pip install psycopg2-binary python-dotenv
"""

import os
import re
import sys
from datetime import datetime
from itertools import groupby

import psycopg2
import psycopg2.extras

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass  # Not installed — rely on environment variables being set externally

# ── Config ───────────────────────────────────────────────────────────────────

VALID_STATUSES = {'pending', 'paid', 'picked_up'}


def get_connection():
    url = os.environ.get('DATABASE_URL')
    if not url:
        sys.exit("DATABASE_URL environment variable is not set.")
    return psycopg2.connect(url, cursor_factory=psycopg2.extras.RealDictCursor)


# ── Data Cleaning ─────────────────────────────────────────────────────────────
# Input validation runs before any DB write. Parameterized queries in psycopg2
# already prevent SQL injection, but we also reject malformed values early so
# error_note messages are meaningful.

def clean_text(value, field_name):
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field_name}: expected text, got {type(value).__name__}")
    return value.strip()


def clean_insta_handle(value):
    value = clean_text(value, 'insta_handle')
    if not value:
        raise ValueError("insta_handle: must not be empty")
    value = value.lstrip('@').lower()
    if not re.match(r'^[\w.]+$', value):
        raise ValueError(f"insta_handle: invalid characters in '{value}'")
    return value


def clean_positive_integer(value, field_name):
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field_name}: expected integer, got '{value}'")
    if value <= 0:
        raise ValueError(f"{field_name}: must be greater than 0")
    return value


def clean_price(value, field_name):
    try:
        value = round(float(value), 2)
    except (TypeError, ValueError):
        raise ValueError(f"{field_name}: expected a number, got '{value}'")
    if value < 0:
        raise ValueError(f"{field_name}: price cannot be negative")
    return value


def clean_date(value, field_name):
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, str):
        for fmt in ('%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%d'):
            try:
                return datetime.strptime(value[:len(fmt)], fmt).date()
            except ValueError:
                continue
        try:
            return datetime.fromisoformat(value).date()
        except ValueError:
            pass
    raise ValueError(f"{field_name}: expected YYYY-MM-DD, got '{value}'")


def clean_status(value):
    value = value.strip().lower() if isinstance(value, str) else ''
    if value not in VALID_STATUSES:
        raise ValueError(f"status: '{value}' is not valid. Use: {VALID_STATUSES}")
    return value


def clean_entry(row):
    return {
        'id':               row['id'],
        'customer_name':    clean_text(row.get('customer_name'), 'customer_name'),
        'insta_handle':     clean_insta_handle(row.get('insta_handle')),
        'order_date':       clean_date(row.get('order_date'), 'order_date'),
        'paypal_reference': clean_text(row.get('paypal_reference'), 'paypal_reference'),
        'variant_id':       clean_text(row.get('variant_id'), 'variant_id'),
        'quantity':         clean_positive_integer(row.get('quantity'), 'quantity'),
        'unit_price':       clean_price(row.get('unit_price'), 'unit_price'),
        'status':           clean_status(row.get('status', 'paid')),
    }


# ── Read ──────────────────────────────────────────────────────────────────────

def get_unprocessed_entries(conn):
    with conn.cursor() as cur:
        cur.execute("""
            SELECT * FROM order_entry
            WHERE status = 'paid' AND processed = FALSE
            ORDER BY paypal_reference, id
        """)
        rows = cur.fetchall()
    print(f"Unprocessed entries: {len(rows)}")
    return rows


# ── Customers ─────────────────────────────────────────────────────────────────

def upsert_customer(cur, entry):
    """Insert customer if not exists; return customers.id in both cases."""
    cur.execute("""
        INSERT INTO customers (customer_name, insta_handle)
        VALUES (%s, %s)
        ON CONFLICT (insta_handle) DO UPDATE SET insta_handle = EXCLUDED.insta_handle
        RETURNING id
    """, (entry['customer_name'], entry['insta_handle']))
    customer_id = cur.fetchone()['id']
    print(f"  Customer upserted: id={customer_id} ({entry['insta_handle']})")
    return customer_id


# ── Orders ────────────────────────────────────────────────────────────────────

def next_order_id(cur):
    """Generate the next sequential business-facing order_id."""
    cur.execute("SELECT COALESCE(MAX(order_id), 1000) + 1 AS next FROM orders")
    return cur.fetchone()['next']


def insert_order(cur, customer_id, entry):
    order_id = next_order_id(cur)
    cur.execute("""
        INSERT INTO orders (order_id, customer_id, order_date, status, paypal_reference)
        VALUES (%s, %s, %s, %s, %s)
        RETURNING id
    """, (order_id, customer_id, entry['order_date'], entry['status'], entry['paypal_reference']))
    db_id = cur.fetchone()['id']
    print(f"  Order inserted: order_id={order_id}, id={db_id}")
    return db_id


# ── Variants & Stock ──────────────────────────────────────────────────────────

def fetch_variant_for_update(cur, variant_id_text):
    """Lock the variant row for the duration of the transaction."""
    cur.execute("""
        SELECT id, current_stock FROM product_variants
        WHERE variant_id = %s
        FOR UPDATE
    """, (variant_id_text,))
    row = cur.fetchone()
    if row is None:
        raise ValueError(f"variant_id '{variant_id_text}' not found in product_variants")
    return row


def update_stock(cur, variant_db_id, variant_id_text, quantity, current_stock):
    new_stock = current_stock - quantity
    if new_stock < 0:
        raise ValueError(
            f"variant '{variant_id_text}': insufficient stock "
            f"(current: {current_stock}, requested: {quantity})"
        )
    cur.execute(
        "UPDATE product_variants SET current_stock = %s WHERE id = %s",
        (new_stock, variant_db_id)
    )


# ── Order Items ───────────────────────────────────────────────────────────────

def insert_order_item(cur, order_db_id, variant_db_id, entry):
    cur.execute("""
        INSERT INTO order_items (order_id, variant_id, quantity, unit_price)
        VALUES (%s, %s, %s, %s)
    """, (order_db_id, variant_db_id, entry['quantity'], entry['unit_price']))


# ── Processed Flag ────────────────────────────────────────────────────────────

def mark_processed(conn, row_ids):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE order_entry SET processed = TRUE WHERE id = ANY(%s)",
            (row_ids,)
        )
    conn.commit()


def mark_failed(conn, row_ids, reason):
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE order_entry SET processed = FALSE, error_note = %s WHERE id = ANY(%s)",
            (reason, row_ids)
        )
    conn.commit()


# ── Main ──────────────────────────────────────────────────────────────────────

def run():
    conn = get_connection()
    print("Connected to database")

    raw_entries = get_unprocessed_entries(conn)
    if not raw_entries:
        print("No unprocessed entries. Done.")
        conn.close()
        return

    cleaned, skipped_ids = [], []
    for row in raw_entries:
        try:
            cleaned.append(clean_entry(row))
            print(f"  CLEANED row id={row['id']}")
        except ValueError as e:
            print(f"  SKIPPED row id={row['id']}: {e}")
            mark_failed(conn, [row['id']], str(e))

    if not cleaned:
        print("No valid entries after cleaning.")
        conn.close()
        return

    cleaned.sort(key=lambda e: e['paypal_reference'])
    groups = groupby(cleaned, key=lambda e: e['paypal_reference'])

    for paypal_ref, items in groups:
        items = list(items)
        row_ids = [i['id'] for i in items]
        print(f"Processing paypal_ref '{paypal_ref}' ({len(items)} item(s))")
        try:
            with conn:
                with conn.cursor() as cur:
                    customer_id = upsert_customer(cur, items[0])
                    order_db_id = insert_order(cur, customer_id, items[0])

                    for item in items:
                        variant = fetch_variant_for_update(cur, item['variant_id'])
                        update_stock(cur, variant['id'], item['variant_id'], item['quantity'], variant['current_stock'])
                        insert_order_item(cur, order_db_id, variant['id'], item)
                        print(f"  Item inserted: variant={item['variant_id']}, qty={item['quantity']}")

            mark_processed(conn, row_ids)
            print(f"OK — paypal_ref '{paypal_ref}' → {len(items)} item(s)")

        except Exception as e:
            print(f"FAILED — paypal_ref '{paypal_ref}': {e}")
            mark_failed(conn, row_ids, str(e))

    conn.close()
    print("Done.")


if __name__ == '__main__':
    run()
