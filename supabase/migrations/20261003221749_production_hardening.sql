-- Production hardening: secure rate-limit storage, deterministic checkout locking,
-- customer metric consistency, valid order/product/discount values, and shipping copy.

ALTER TABLE private.cod_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.cod_rate_limits FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS "service role cod rate limits" ON private.cod_rate_limits;
CREATE POLICY "service role cod rate limits"
ON private.cod_rate_limits
AS PERMISSIVE
FOR ALL
TO service_role
USING (true)
WITH CHECK (true);
GRANT ALL ON TABLE private.cod_rate_limits TO service_role;

DROP FUNCTION IF EXISTS public.place_cod_order(text,text,text,text,text,jsonb,text);

-- The canonical 8-argument place_cod_order definition is maintained here from the
-- production function with deterministic product locking and customer-key locking.
-- It is intentionally SECURITY DEFINER because it performs the atomic COD transaction.
CREATE OR REPLACE FUNCTION public.place_cod_order(
  p_customer_name text, p_phone text, p_city text, p_address text, p_notes text,
  p_items jsonb, p_idempotency_key text, p_discount_code text
)
RETURNS TABLE(order_id uuid, order_number bigint, subtotal numeric, discount_amount numeric, shipping numeric, total numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
SET statement_timeout TO '4s'
AS $function$
DECLARE
  v_customer_id uuid;
  v_order_id uuid;
  v_order_number bigint;
  v_subtotal numeric := 0;
  v_discount_amount numeric := 0;
  v_shipping numeric := 20;
  v_total numeric;
  v_item jsonb;
  v_product_id uuid;
  v_qty integer;
  v_price numeric;
  v_stock integer;
  v_name text;
  v_status text;
  v_digits text;
  v_phone text;
  v_headers json;
  v_ip text;
  v_recent_attempts integer;
  v_existing record;
  v_discount_id uuid;
  v_discount_type text;
  v_discount_value numeric;
  v_discount_min numeric;
  v_discount_max_uses integer;
  v_discount_used_count integer;
  v_discount_starts_at timestamptz;
  v_discount_ends_at timestamptz;
  v_discount_active boolean;
  v_code text;
BEGIN
  IF coalesce(length(trim(p_idempotency_key)),0) < 20
     OR length(trim(p_idempotency_key)) > 100 THEN
    RAISE EXCEPTION 'Invalid order request. Please try again.';
  END IF;

  SELECT o.id, o.order_number, o.subtotal, o.discount_amount, o.shipping, o.total
  INTO v_existing
  FROM public.orders o
  WHERE o.idempotency_key = trim(p_idempotency_key)
  LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    RETURN QUERY SELECT v_existing.id, v_existing.order_number,
                         v_existing.subtotal, v_existing.discount_amount,
                         v_existing.shipping, v_existing.total;
    RETURN;
  END IF;

  v_headers := nullif(current_setting('request.headers', true), '')::json;
  v_ip := coalesce(v_headers->>'cf-connecting-ip', null);
  IF v_ip IS NOT NULL AND length(trim(v_ip)) BETWEEN 7 AND 64 THEN
    v_ip := trim(v_ip);
    DELETE FROM private.cod_rate_limits
    WHERE ip = v_ip AND request_at < now() - interval '1 hour';

    SELECT count(*) INTO v_recent_attempts
    FROM private.cod_rate_limits
    WHERE ip = v_ip AND request_at >= now() - interval '5 minutes';

    IF v_recent_attempts >= 12 THEN
      RAISE EXCEPTION 'Too many order attempts. Please wait a few minutes and try again.';
    END IF;

    INSERT INTO private.cod_rate_limits(ip) VALUES(v_ip);
  END IF;

  IF coalesce(length(trim(p_customer_name)),0) < 2
     OR length(trim(p_customer_name)) > 120 THEN
    RAISE EXCEPTION 'Please enter your full name.';
  END IF;

  v_digits := regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');

  IF v_digits ~ '^212[567][0-9]{8}$' THEN
    v_phone := '+' || v_digits;
  ELSIF v_digits ~ '^0[567][0-9]{8}$' THEN
    v_phone := '+212' || substring(v_digits from 2);
  ELSIF v_digits ~ '^[567][0-9]{8}$' THEN
    v_phone := '+212' || v_digits;
  ELSE
    RAISE EXCEPTION 'Please enter a valid Moroccan phone number.';
  END IF;

  IF coalesce(length(trim(p_city)),0) < 2
     OR length(trim(p_city)) > 80 THEN
    RAISE EXCEPTION 'Please enter your city.';
  END IF;

  IF coalesce(length(trim(p_address)),0) < 2
     OR length(trim(p_address)) > 240 THEN
    RAISE EXCEPTION 'Please enter your area or address.';
  END IF;

  IF jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0
     OR jsonb_array_length(p_items) > 20 THEN
    RAISE EXCEPTION 'Your cart is empty or contains too many items.';
  END IF;

  IF (
    SELECT count(*) FROM jsonb_array_elements(p_items) x
  ) <> (
    SELECT count(distinct (x->>'product_id')) FROM jsonb_array_elements(p_items) x
  ) THEN
    RAISE EXCEPTION 'Invalid cart. Please review your items and try again.';
  END IF;

  SELECT coalesce(s.shipping_fee,20) INTO v_shipping
  FROM public.site_settings s WHERE s.id = true;
  v_shipping := greatest(coalesce(v_shipping,20),0);

  FOR v_item IN
    SELECT x
    FROM jsonb_array_elements(p_items) AS x
    ORDER BY (x->>'product_id')::uuid
  LOOP
    BEGIN
      v_product_id := (v_item->>'product_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Invalid product in cart.';
    END;

    v_qty := (v_item->>'quantity')::integer;
    IF v_qty IS NULL OR v_qty < 1 OR v_qty > 99 THEN
      RAISE EXCEPTION 'Invalid product quantity.';
    END IF;

    SELECT p.name, p.price, p.stock, p.status
    INTO v_name, v_price, v_stock, v_status
    FROM public.products p WHERE p.id = v_product_id FOR UPDATE;

    IF NOT FOUND OR v_status <> 'active' THEN
      RAISE EXCEPTION 'One of the products is no longer available.';
    END IF;

    IF v_stock < v_qty THEN
      RAISE EXCEPTION 'Not enough stock for %.', v_name;
    END IF;

    v_subtotal := v_subtotal + (v_price * v_qty);
  END LOOP;

  IF v_subtotal >= 160 THEN
    v_shipping := 0;
  END IF;

  v_code := upper(trim(coalesce(p_discount_code,'')));

  IF v_code <> '' THEN
    SELECT d.id, d.type, d.value, d.min_order_value, d.max_uses,
           d.used_count, d.starts_at, d.ends_at, d.active
    INTO v_discount_id, v_discount_type, v_discount_value, v_discount_min,
         v_discount_max_uses, v_discount_used_count, v_discount_starts_at,
         v_discount_ends_at, v_discount_active
    FROM public.discounts d
    WHERE upper(d.code) = v_code
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND OR NOT coalesce(v_discount_active,false) THEN
      RAISE EXCEPTION 'This discount code is not valid.';
    END IF;

    IF v_discount_starts_at IS NOT NULL AND now() < v_discount_starts_at THEN
      RAISE EXCEPTION 'This discount code is not active yet.';
    END IF;

    IF v_discount_ends_at IS NOT NULL AND now() > v_discount_ends_at THEN
      RAISE EXCEPTION 'This discount code has expired.';
    END IF;

    IF v_discount_max_uses IS NOT NULL AND v_discount_used_count >= v_discount_max_uses THEN
      RAISE EXCEPTION 'This discount code has reached its usage limit.';
    END IF;

    IF v_subtotal < coalesce(v_discount_min,0) THEN
      RAISE EXCEPTION 'This discount requires a minimum order of % DH.', v_discount_min;
    END IF;

    IF v_discount_type = 'percentage' THEN
      v_discount_amount := round(v_subtotal * v_discount_value / 100, 2);
    ELSIF v_discount_type = 'fixed' THEN
      v_discount_amount := least(v_discount_value, v_subtotal);
    ELSE
      RAISE EXCEPTION 'This discount code is misconfigured.';
    END IF;

    v_discount_amount := greatest(least(v_discount_amount, v_subtotal),0);

    UPDATE public.discounts
    SET used_count = coalesce(used_count,0) + 1
    WHERE id = v_discount_id;
  END IF;

  v_total := greatest(v_subtotal - v_discount_amount,0) + v_shipping;

  -- Serialize concurrent checkouts for the same customer phone so the
  -- unique customer index cannot turn a legitimate simultaneous checkout
  -- into a transient unique_violation.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_phone, 0));

  SELECT c.id INTO v_customer_id
  FROM public.customers c
  WHERE c.phone_normalized = v_phone
  ORDER BY c.updated_at DESC
  LIMIT 1;

  IF v_customer_id IS NULL THEN
    INSERT INTO public.customers(
      name, phone, phone_normalized, city, address, notes, order_count, total_spent
    )
    VALUES(
      trim(p_customer_name), v_phone, v_phone, trim(p_city),
      trim(p_address), nullif(trim(p_notes),''), 1, v_total
    )
    RETURNING id INTO v_customer_id;
  ELSE
    UPDATE public.customers
    SET name = trim(p_customer_name),
        phone = v_phone,
        phone_normalized = v_phone,
        city = trim(p_city),
        address = trim(p_address),
        notes = coalesce(nullif(trim(p_notes),''), notes),
        order_count = coalesce(order_count,0) + 1,
        total_spent = coalesce(total_spent,0) + v_total,
        updated_at = now()
    WHERE id = v_customer_id;
  END IF;

  INSERT INTO public.orders(
    customer_id, customer_name, phone, city, address, notes,
    subtotal, discount_code, discount_amount, shipping, total,
    payment_method, status, idempotency_key
  )
  VALUES(
    v_customer_id, trim(p_customer_name), v_phone, trim(p_city),
    trim(p_address), nullif(trim(p_notes),''), v_subtotal,
    nullif(v_code,''), v_discount_amount, v_shipping,
    v_total, 'cod', 'new', trim(p_idempotency_key)
  )
  RETURNING public.orders.id, public.orders.order_number
  INTO v_order_id, v_order_number;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;

    SELECT p.name, p.price INTO v_name, v_price
    FROM public.products p WHERE p.id = v_product_id;

    INSERT INTO public.order_items(
      order_id, product_id, product_name, unit_price, quantity, line_total
    )
    VALUES(v_order_id, v_product_id, v_name, v_price, v_qty, v_price * v_qty);

    UPDATE public.products
    SET stock = stock - v_qty, updated_at = now()
    WHERE id = v_product_id;
  END LOOP;

  RETURN QUERY SELECT v_order_id, v_order_number, v_subtotal,
                       v_discount_amount, v_shipping, v_total;

EXCEPTION
  WHEN unique_violation THEN
    SELECT o.id, o.order_number, o.subtotal, o.discount_amount, o.shipping, o.total
    INTO v_existing
    FROM public.orders o
    WHERE o.idempotency_key = trim(p_idempotency_key)
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
      RETURN QUERY SELECT v_existing.id, v_existing.order_number,
                           v_existing.subtotal, v_existing.discount_amount,
                           v_existing.shipping, v_existing.total;
      RETURN;
    END IF;
    RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.place_cod_order(text,text,text,text,text,jsonb,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.place_cod_order(text,text,text,text,text,jsonb,text,text) TO service_role;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='orders_status_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_status_check
      CHECK (status IN ('new','confirmed','processing','shipped','delivered','cancelled','returned'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='products_price_nonnegative') THEN
    ALTER TABLE public.products ADD CONSTRAINT products_price_nonnegative CHECK (price >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='products_stock_nonnegative') THEN
    ALTER TABLE public.products ADD CONSTRAINT products_stock_nonnegative CHECK (stock >= 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='discounts_value_positive') THEN
    ALTER TABLE public.discounts ADD CONSTRAINT discounts_value_positive CHECK (value > 0);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='discounts_type_check') THEN
    ALTER TABLE public.discounts ADD CONSTRAINT discounts_type_check CHECK (type IN ('percentage','fixed'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.sync_customer_stats()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF TG_OP <> 'INSERT' AND OLD.customer_id IS NOT NULL THEN
    UPDATE public.customers c
    SET order_count = (
          SELECT count(*) FROM public.orders o
          WHERE o.customer_id = OLD.customer_id
            AND o.status NOT IN ('cancelled','returned')
        ),
        total_spent = COALESCE((
          SELECT sum(o.total) FROM public.orders o
          WHERE o.customer_id = OLD.customer_id
            AND o.status NOT IN ('cancelled','returned')
        ),0),
        updated_at = now()
    WHERE c.id = OLD.customer_id;
  END IF;

  IF TG_OP <> 'DELETE' AND NEW.customer_id IS NOT NULL THEN
    UPDATE public.customers c
    SET order_count = (
          SELECT count(*) FROM public.orders o
          WHERE o.customer_id = NEW.customer_id
            AND o.status NOT IN ('cancelled','returned')
        ),
        total_spent = COALESCE((
          SELECT sum(o.total) FROM public.orders o
          WHERE o.customer_id = NEW.customer_id
            AND o.status NOT IN ('cancelled','returned')
        ),0),
        updated_at = now()
    WHERE c.id = NEW.customer_id;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$function$;

DROP TRIGGER IF EXISTS sync_customer_stats_on_orders ON public.orders;
CREATE TRIGGER sync_customer_stats_on_orders
AFTER INSERT OR UPDATE OF status, total, customer_id OR DELETE
ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.sync_customer_stats();

REVOKE ALL ON FUNCTION public.sync_customer_stats() FROM PUBLIC, anon, authenticated;

UPDATE public.customers c
SET order_count = (
      SELECT count(*) FROM public.orders o
      WHERE o.customer_id = c.id
        AND o.status NOT IN ('cancelled','returned')
    ),
    total_spent = COALESCE((
      SELECT sum(o.total) FROM public.orders o
      WHERE o.customer_id = c.id
        AND o.status NOT IN ('cancelled','returned')
    ),0),
    updated_at = now();

UPDATE public.site_settings
SET announcement_text = 'FREE delivery on orders of 160 DH or more',
    updated_at = now()
WHERE id = true
  AND lower(coalesce(announcement_text,'')) = 'free delivery on orders over 160 dh';
