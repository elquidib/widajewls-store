alter table public.orders
  add column if not exists discount_code text,
  add column if not exists discount_amount numeric not null default 0;

alter table public.orders
  add constraint orders_discount_amount_nonnegative
  check (discount_amount >= 0);

create or replace function public.place_cod_order(
  p_customer_name text,
  p_phone text,
  p_city text,
  p_address text,
  p_notes text,
  p_items jsonb,
  p_idempotency_key text,
  p_discount_code text
)
returns table(
  order_id uuid,
  order_number bigint,
  subtotal numeric,
  discount_amount numeric,
  shipping numeric,
  total numeric
)
language plpgsql
security definer
set search_path to ''
set statement_timeout to '4s'
as $function$
declare
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
begin
  if coalesce(length(trim(p_idempotency_key)),0) < 20
     or length(trim(p_idempotency_key)) > 100 then
    raise exception 'Invalid order request. Please try again.';
  end if;

  select o.id, o.order_number, o.subtotal, o.discount_amount, o.shipping, o.total
  into v_existing
  from public.orders o
  where o.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    return query select v_existing.id, v_existing.order_number,
                         v_existing.subtotal, v_existing.discount_amount,
                         v_existing.shipping, v_existing.total;
    return;
  end if;

  v_headers := nullif(current_setting('request.headers', true), '')::json;
  v_ip := coalesce(v_headers->>'cf-connecting-ip', null);
  if v_ip is not null and length(trim(v_ip)) between 7 and 64 then
    v_ip := trim(v_ip);
    delete from private.cod_rate_limits
    where ip = v_ip and request_at < now() - interval '1 hour';

    select count(*) into v_recent_attempts
    from private.cod_rate_limits
    where ip = v_ip and request_at >= now() - interval '5 minutes';

    if v_recent_attempts >= 12 then
      raise exception 'Too many order attempts. Please wait a few minutes and try again.';
    end if;

    insert into private.cod_rate_limits(ip) values(v_ip);
  end if;

  if coalesce(length(trim(p_customer_name)),0) < 2
     or length(trim(p_customer_name)) > 120 then
    raise exception 'Please enter your full name.';
  end if;

  v_digits := regexp_replace(coalesce(p_phone,''),'[^0-9]','','g');

  if v_digits ~ '^212[567][0-9]{8}$' then
    v_phone := '+' || v_digits;
  elsif v_digits ~ '^0[567][0-9]{8}$' then
    v_phone := '+212' || substring(v_digits from 2);
  elsif v_digits ~ '^[567][0-9]{8}$' then
    v_phone := '+212' || v_digits;
  else
    raise exception 'Please enter a valid Moroccan phone number.';
  end if;

  if coalesce(length(trim(p_city)),0) < 2
     or length(trim(p_city)) > 80 then
    raise exception 'Please enter your city.';
  end if;

  if coalesce(length(trim(p_address)),0) < 2
     or length(trim(p_address)) > 240 then
    raise exception 'Please enter your area or address.';
  end if;

  if jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 20 then
    raise exception 'Your cart is empty or contains too many items.';
  end if;

  if (
    select count(*) from jsonb_array_elements(p_items) x
  ) <> (
    select count(distinct (x->>'product_id')) from jsonb_array_elements(p_items) x
  ) then
    raise exception 'Invalid cart. Please review your items and try again.';
  end if;

  select coalesce(s.shipping_fee,20) into v_shipping
  from public.site_settings s where s.id = true;
  v_shipping := greatest(coalesce(v_shipping,20),0);

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
    exception when invalid_text_representation then
      raise exception 'Invalid product in cart.';
    end;

    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty < 1 or v_qty > 99 then
      raise exception 'Invalid product quantity.';
    end if;

    select p.name, p.price, p.stock, p.status
    into v_name, v_price, v_stock, v_status
    from public.products p where p.id = v_product_id for update;

    if not found or v_status <> 'active' then
      raise exception 'One of the products is no longer available.';
    end if;

    if v_stock < v_qty then
      raise exception 'Not enough stock for %.', v_name;
    end if;

    v_subtotal := v_subtotal + (v_price * v_qty);
  end loop;

  v_code := upper(trim(coalesce(p_discount_code,'')));

  if v_code <> '' then
    select d.id, d.type, d.value, d.min_order_value, d.max_uses,
           d.used_count, d.starts_at, d.ends_at, d.active
    into v_discount_id, v_discount_type, v_discount_value, v_discount_min,
         v_discount_max_uses, v_discount_used_count, v_discount_starts_at,
         v_discount_ends_at, v_discount_active
    from public.discounts d
    where upper(d.code) = v_code
    limit 1
    for update;

    if not found or not coalesce(v_discount_active,false) then
      raise exception 'This discount code is not valid.';
    end if;

    if v_discount_starts_at is not null and now() < v_discount_starts_at then
      raise exception 'This discount code is not active yet.';
    end if;

    if v_discount_ends_at is not null and now() > v_discount_ends_at then
      raise exception 'This discount code has expired.';
    end if;

    if v_discount_max_uses is not null and v_discount_used_count >= v_discount_max_uses then
      raise exception 'This discount code has reached its usage limit.';
    end if;

    if v_subtotal < coalesce(v_discount_min,0) then
      raise exception 'This discount requires a minimum order of % DH.', v_discount_min;
    end if;

    if v_discount_type = 'percentage' then
      v_discount_amount := round(v_subtotal * v_discount_value / 100, 2);
    elsif v_discount_type = 'fixed' then
      v_discount_amount := least(v_discount_value, v_subtotal);
    else
      raise exception 'This discount code is misconfigured.';
    end if;

    v_discount_amount := greatest(least(v_discount_amount, v_subtotal),0);

    update public.discounts
    set used_count = coalesce(used_count,0) + 1
    where id = v_discount_id;
  end if;

  v_total := greatest(v_subtotal - v_discount_amount,0) + v_shipping;

  select c.id into v_customer_id
  from public.customers c
  where c.phone_normalized = v_phone
  order by c.updated_at desc
  limit 1;

  if v_customer_id is null then
    insert into public.customers(
      name, phone, phone_normalized, city, address, notes, order_count, total_spent
    )
    values(
      trim(p_customer_name), v_phone, v_phone, trim(p_city),
      trim(p_address), nullif(trim(p_notes),''), 1, v_total
    )
    returning id into v_customer_id;
  else
    update public.customers
    set name = trim(p_customer_name),
        phone = v_phone,
        phone_normalized = v_phone,
        city = trim(p_city),
        address = trim(p_address),
        notes = coalesce(nullif(trim(p_notes),''), notes),
        order_count = coalesce(order_count,0) + 1,
        total_spent = coalesce(total_spent,0) + v_total,
        updated_at = now()
    where id = v_customer_id;
  end if;

  insert into public.orders(
    customer_id, customer_name, phone, city, address, notes,
    subtotal, discount_code, discount_amount, shipping, total,
    payment_method, status, idempotency_key
  )
  values(
    v_customer_id, trim(p_customer_name), v_phone, trim(p_city),
    trim(p_address), nullif(trim(p_notes),''), v_subtotal,
    nullif(v_code,''), v_discount_amount, v_shipping,
    v_total, 'cod', 'new', trim(p_idempotency_key)
  )
  returning public.orders.id, public.orders.order_number
  into v_order_id, v_order_number;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;

    select p.name, p.price into v_name, v_price
    from public.products p where p.id = v_product_id;

    insert into public.order_items(
      order_id, product_id, product_name, unit_price, quantity, line_total
    )
    values(v_order_id, v_product_id, v_name, v_price, v_qty, v_price * v_qty);

    update public.products
    set stock = stock - v_qty, updated_at = now()
    where id = v_product_id;
  end loop;

  return query select v_order_id, v_order_number, v_subtotal,
                       v_discount_amount, v_shipping, v_total;

exception
  when unique_violation then
    select o.id, o.order_number, o.subtotal, o.discount_amount, o.shipping, o.total
    into v_existing
    from public.orders o
    where o.idempotency_key = trim(p_idempotency_key)
    limit 1;

    if v_existing.id is not null then
      return query select v_existing.id, v_existing.order_number,
                           v_existing.subtotal, v_existing.discount_amount,
                           v_existing.shipping, v_existing.total;
      return;
    end if;
    raise;
end;
$function$;

revoke execute on function public.place_cod_order(text,text,text,text,text,jsonb,text,text) from public, anon, authenticated;
grant execute on function public.place_cod_order(text,text,text,text,text,jsonb,text,text) to service_role;
