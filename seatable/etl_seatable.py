from seatable_api import Base, context
from itertools import groupby
import re
from datetime import datetime

# ── Auth ────────────────────────────────────────────────────────────────────
def auth():
    base = Base(context.api_token, context.server_url)
    base.auth()
    return base

# ── Constants ────────────────────────────────────────────────────────────────
VALID_STATUSES = {'pending', 'paid', 'picked_up'}

# ── Metadata / Link IDs ──────────────────────────────────────────────────────
def get_link_id(metadata, table_name, column_name):
    """Extract the link_id for a linked-record column from base metadata.

    In SeaTable, bidirectional linked columns share a single link_id.
    Fetching it from either side of the relationship works — we use the
    'source' table for clarity.
    """
    for table in metadata.get('tables', []):
        if table['name'] == table_name:
            for col in table.get('columns', []):
                if col['name'] == column_name:
                    link_id = col.get('data', {}).get('link_id')
                    if link_id:
                        return link_id
    raise ValueError(f"Link ID not found for {table_name}.{column_name}")

# ── Data Cleaning ────────────────────────────────────────────────────────────
def clean_text(value, field_name):
    """Trim whitespace and block injection patterns."""
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field_name}: expected text, got {type(value).__name__}")
    value = value.strip()
    # Block SQL injection patterns
    sql_patterns = r"(--|;|\'|\"|\bDROP\b|\bSELECT\b|\bINSERT\b|\bUPDATE\b|\bDELETE\b|\bUNION\b)"
    if re.search(sql_patterns, value, re.IGNORECASE):
        raise ValueError(f"{field_name}: potentially unsafe content detected")
    # Block script injection
    if re.search(r"<.*?>", value):
        raise ValueError(f"{field_name}: HTML/script content not allowed")
    return value

def clean_insta_handle(value):
    """Normalize Instagram handle: lowercase, strip @, alphanumeric and underscores only."""
    value = clean_text(value, 'insta_handle')
    if value is None:
        return None
    value = value.lstrip('@').lower()
    if not re.match(r'^[\w.]+$', value):
        raise ValueError(f"insta_handle: invalid characters in '{value}'")
    return value

def clean_positive_integer(value, field_name):
    """Ensure value is a positive integer."""
    try:
        value = int(value)
    except (TypeError, ValueError):
        raise ValueError(f"{field_name}: expected integer, got '{value}'")
    if value <= 0:
        raise ValueError(f"{field_name}: must be greater than 0")
    return value

def clean_price(value, field_name):
    """Ensure value is a non-negative number with max 2 decimal places."""
    try:
        value = round(float(value), 2)
    except (TypeError, ValueError):
        raise ValueError(f"{field_name}: expected a number, got '{value}'")
    if value < 0:
        raise ValueError(f"{field_name}: price cannot be negative")
    return value

def clean_date(value, field_name):
    """Ensure date is a valid YYYY-MM-DD string. Handles SeaTable ISO 8601 format."""
    if isinstance(value, datetime):
        return value.strftime('%Y-%m-%d')
    if isinstance(value, str):
        # Handle SeaTable's ISO 8601 format: 2026-04-03T00:00:00+02:00
        try:
            return datetime.fromisoformat(value).strftime('%Y-%m-%d')
        except ValueError:
            pass
        # Fallback: plain YYYY-MM-DD
        try:
            datetime.strptime(value, '%Y-%m-%d')
            return value
        except ValueError:
            pass
    raise ValueError(f"{field_name}: expected YYYY-MM-DD format, got '{value}'")

def clean_status(value):
    """Validate order status against allowed values."""
    value = value.strip().lower() if isinstance(value, str) else ''
    if value not in VALID_STATUSES:
        raise ValueError(f"status: '{value}' is not valid. Use: {VALID_STATUSES}")
    return value

def extract_linked_value(value, field_name):
    """Extract display_value from SeaTable linked record format."""
    if isinstance(value, list) and len(value) > 0:
        first = value[0]
        # Dict format: [{'row_id': '...', 'display_value': '...'}]
        if isinstance(first, dict):
            return first.get('display_value', '').strip()
        # Plain string format: ['some_value']
        if isinstance(first, str):
            return first.strip()
    if isinstance(value, str):
        return value.strip()
    raise ValueError(f"{field_name}: unexpected format '{value}'")

def clean_entry(entry):
    print(f"  variant_id raw: {entry.get('variant_id')}")
    return {
        '_id':              entry['_id'],
        'customer_name':    clean_text(entry.get('customer_name'), 'customer_name'),
        'insta_handle':     clean_insta_handle(entry.get('insta_handle')),
        'order_date':       clean_date(entry.get('order_date'), 'order_date'),
        'paypal_reference': clean_text(entry.get('paypal_reference'), 'paypal_reference'),
        'variant_id':       extract_linked_value(entry.get('variant_id'), 'variant_id'),
        'quantity':         clean_positive_integer(entry.get('quantity'), 'quantity'),
        'unit_price':       clean_price(entry.get('unit_price'), 'unit_price'),
        'status':           clean_status(entry.get('status', 'paid')),
    }

# ── Read ─────────────────────────────────────────────────────────────────────
def get_unprocessed_entries(base):
    rows = base.list_rows('order_entry')
    print(f"Raw rows returned: {len(rows)}")
    result = []
    for row in rows:
        raw_processed = row.get('processed')
        raw_status    = row.get('status', '')
        is_unprocessed = raw_processed != 1
        is_paid        = raw_status == 'paid'
        # print(f"  row {row['_id']}: processed={raw_processed} → unprocessed={is_unprocessed} | status='{raw_status}' | is_paid={is_paid} | include={is_unprocessed and is_paid}")
        if is_unprocessed and is_paid:
            result.append(row)
    print(f"Unprocessed entries: {len(result)}")
    return result

# ── Customers ────────────────────────────────────────────────────────────────
def upsert_customer(base, entry):
    handle = entry['insta_handle']
    matches = base.filter('customers', f"insta_handle = '{handle}'")
    if matches:
        print(f"  Customer found: {matches[0]['_id']}")
        return matches[0]['_id']
    row = base.append_row('customers', {
        'customer_name': entry['customer_name'],  # fix: was 'name'
        'insta_handle':  handle
    })
    print(f"  Customer created: {row['_id']}")
    return row['_id']

# ── Orders ────────────────────────────────────────────────────────────────────
def generate_order_id(base):
    existing = base.list_rows('orders')
    if not existing:
        return 1
    return max(int(o.get('order_id', 0)) for o in existing) + 1

def insert_order(base, order_id, entry):
    """Insert order row with scalar fields only.
    customer_id and order_items are linked columns — set via add_link after insert.
    """
    row = base.append_row('orders', {
        'order_id':         order_id,
        'order_date':       entry['order_date'],
        'status':           entry['status'],
        'paypal_reference': entry['paypal_reference']
    })
    return row['_id']

def insert_order_item(base, entry):
    """Insert order_item row with scalar fields only.
    order_id and variant_id are linked columns — set via add_link after insert.
    """
    row = base.append_row('order_items', {
        'quantity':   entry['quantity'],
        'unit_price': entry['unit_price']
    })
    return row['_id']

# ── Stock ─────────────────────────────────────────────────────────────────────
def get_variant_row(base, variant_id):
    """Fetch the product_variants row for a given variant_id string."""
    matches = base.filter('product_variants', f"variant_id = '{variant_id}'")
    if not matches:
        raise ValueError(f"variant_id '{variant_id}' not found in product_variants")
    return matches[0]

def update_stock(base, variant_row, quantity):
    new_stock = variant_row['current_stock'] - quantity
    if new_stock < 0:
        raise ValueError(
            f"variant_id '{variant_row.get('variant_id')}': insufficient stock "
            f"(current: {variant_row['current_stock']}, requested: {quantity})"
        )
    base.update_row('product_variants', variant_row['_id'], {'current_stock': new_stock})

# ── Processed Flag ────────────────────────────────────────────────────────────
def mark_processed(base, row_id):
    base.update_row('order_entry', row_id, {'processed': 1})

def mark_failed(base, row_id, reason):
    base.update_row('order_entry', row_id, {
        'processed':  0,
        'error_note': reason
    })

# ── Main ─────────────────────────────────────────────────────────────────────
# Note: the warning "Couldn't create 'seatable_api.parsetab'" is harmless.
# It comes from the PLY parser library used internally by seatable_api and means
# it can't cache its parse table due to the read-only filesystem in SeaTable's
# Python runner. It has no effect on script behaviour.
def run():
    base = auth()
    print("Base loaded")

    # Fetch link IDs once from metadata — required for add_link calls.
    # Linked-record columns cannot be written via append_row/update_row.
    metadata = base.get_metadata()
    link_customer_orders = get_link_id(metadata, 'customers',   'orders')
    link_order_items_rel = get_link_id(metadata, 'orders',      'order_items')
    link_item_variant    = get_link_id(metadata, 'order_items', 'variant_id')
    print("Link IDs loaded")

    raw_entries = get_unprocessed_entries(base)
    print("Unprocessed raw_entries loaded")

    if not raw_entries:
        print("No unprocessed entries found.")
        return

    # Clean all entries — mark failed and skip malformed rows
    cleaned_entries = []
    for raw in raw_entries:
        try:
            cleaned_entries.append(clean_entry(raw))
            print(f"  CLEANED row {raw['_id']}")
        except ValueError as e:
            print(f"  SKIPPED row {raw['_id']}: {e}")
            mark_failed(base, raw['_id'], str(e))

    if not cleaned_entries:
        print("No valid entries after cleaning.")
        return

    # Group by paypal_reference to reconstruct multi-item orders
    cleaned_entries.sort(key=lambda e: e['paypal_reference'])
    grouped = groupby(cleaned_entries, key=lambda e: e['paypal_reference'])

    for paypal_ref, items in grouped:
        items = list(items)
        print(f"Processing paypal_ref '{paypal_ref}' ({len(items)} item(s))")
        try:
            customer_row_id = upsert_customer(base, items[0])
            print(f"  Customer upserted: {customer_row_id}")

            order_id = generate_order_id(base)
            order_row_id = insert_order(base, order_id, items[0])
            print(f"  Order inserted: order_id={order_id}, row_id={order_row_id}")

            # Link order → customer (bidirectional: also populates customers.orders)
            base.add_link(link_customer_orders, 'orders', 'customers', order_row_id, customer_row_id)
            print(f"  Linked order → customer")

            for item in items:
                # Fetch variant row up front — needed for both linking and stock update
                variant_row = get_variant_row(base, item['variant_id'])
                print(f"  Variant row found: {variant_row['_id']}")

                item_row_id = insert_order_item(base, item)
                print(f"  Order item inserted: row_id={item_row_id}")

                # Link order_item → order (bidirectional: also populates orders.order_items)
                base.add_link(link_order_items_rel, 'order_items', 'orders', item_row_id, order_row_id)
                print(f"  Linked order_item → order")

                # Link order_item → product_variant
                base.add_link(link_item_variant, 'order_items', 'product_variants', item_row_id, variant_row['_id'])
                print(f"  Linked order_item → variant")

                update_stock(base, variant_row, item['quantity'])
                print(f"  Stock updated: variant_id={item['variant_id']}")

                mark_processed(base, item['_id'])
                print(f"  Marked processed: {item['_id']}")

            print(f"OK — paypal_ref '{paypal_ref}' → order_id {order_id} ({len(items)} item(s))")
        except Exception as e:
            print(f"FAILED — paypal_ref '{paypal_ref}': {e}")
            for item in items:
                mark_failed(base, item['_id'], str(e))

run()
