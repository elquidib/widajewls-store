-- TATTOOUI production hardening: COD checkout, inventory restoration, phone normalization, indexes, and rate limiting.
-- Applied to Supabase project ahvmgdzjfyuhgtgpuavo.

create schema if not exists private;

alter table public.orders
  add column if not exists idempotency_key text,
  add column if not exists stock_restored boolean not null default false;

create unique index if not exists orders_idempotency_key_uidx
  on public.orders (idempotency_key)
  where idempotency_key is not null;

alter table public.customers
  add column if not exists phone_normalized text;

update public.customers
set phone_normalized = case
  when regexp_replace(phone,'[^0-9]','','g') ~ '^212[567][0-9]{8}$'
    then '+' || regexp_replace(phone,'[^0-9]','','g')
  when regexp_replace(phone,'[^0-9]','','g') ~ '^0[567][0-9]{8}$'
    then '+212' || substring(regexp_replace(phone,'[^0-9]','','g') from 2)
  when regexp_replace(phone,'[^0-9]','','g') ~ '^[567][0-9]{8}$'
    then '+212' || regexp_replace(phone,'[^0-9]','','g')
  else regexp_replace(phone,'[^0-9]','','g')
end
where phone_normalized is null;

create unique index if not exists customers_phone_normalized_uidx
  on public.customers (phone_normalized)
  where phone_normalized is not null;

create index if not exists orders_customer_id_idx on public.orders(customer_id);
create index if not exists order_items_product_id_idx on public.order_items(product_id);

create table if not exists private.cod_rate_limits (
  ip text not null,
  request_at timestamptz not null default now()
);

create index if not exists cod_rate_limits_ip_request_at_idx
  on private.cod_rate_limits (ip, request_at desc);

revoke all on table private.cod_rate_limits from public, anon, authenticated;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to postgres, service_role;

create or replace function private.restore_order_stock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  item record;
begin
  if new.status in ('cancelled','returned')
     and old.status is distinct from new.status
     and coalesce(new.stock_restored,false) = false then
    for item in
      select product_id, quantity
      from public.order_items
      where order_id = new.id
        and product_id is not null
    loop
      update public.products
      set stock = stock + item.quantity,
          updated_at = now()
      where id = item.product_id;
    end loop;
    new.stock_restored := true;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_restore_order_stock on public.orders;
create trigger trg_restore_order_stock
before update of status on public.orders
for each row execute function private.restore_order_stock();

drop function if exists public.place_cod_order(text,text,text,text,text,jsonb);

create or replace function public.place_cod_order(
  p_customer_name text,
  p_phone text,
  p_city text,
  p_address text,
  p_notes text,
  p_items jsonb,
  p_idempotency_key text
)
returns table(order_id uuid, order_number bigint, subtotal numeric, shipping numeric, total numeric)
language plpgsql
security definer
set search_path = ''
set statement_timeout = '4s'
as $function$
declare
  v_customer_id uuid;
  v_order_id uuid;
  v_order_number bigint;
  v_subtotal numeric := 0;
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
begin
  if coalesce(length(trim(p_idempotency_key)),0) < 20
     or length(trim(p_idempotency_key)) > 100 then
    raise exception 'Invalid order request. Please try again.';
  end if;

  select o.id, o.order_number, o.subtotal, o.shipping, o.total
  into v_existing
  from public.orders o
  where o.idempotency_key = trim(p_idempotency_key)
  limit 1;

  if v_existing.id is not null then
    return query select v_existing.id, v_existing.order_number,
                         v_existing.subtotal, v_existing.shipping, v_existing.total;
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

  v_total := v_subtotal + v_shipping;

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
    subtotal, shipping, total, payment_method, status, idempotency_key
  )
  values(
    v_customer_id, trim(p_customer_name), v_phone, trim(p_city),
    trim(p_address), nullif(trim(p_notes),''), v_subtotal, v_shipping,
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

  return query select v_order_id, v_order_number, v_subtotal, v_shipping, v_total;

exception
  when unique_violation then
    select o.id, o.order_number, o.subtotal, o.shipping, o.total
    into v_existing
    from public.orders o
    where o.idempotency_key = trim(p_idempotency_key)
    limit 1;

    if v_existing.id is not null then
      return query select v_existing.id, v_existing.order_number,
                           v_existing.subtotal, v_existing.shipping, v_existing.total;
      return;
    end if;
    raise;
end;
$function$;

revoke all on function public.place_cod_order(text,text,text,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.place_cod_order(text,text,text,text,text,jsonb,text) to anon, authenticated, service_role;

 
-- Keep the private rate-limit log easy to maintain and inspect.
alter table private.cod_rate_limits
  add column if not exists id bigint generated by default as identity;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'private.cod_rate_limits'::regclass and contype = 'p'
  ) then
    alter table private.cod_rate_limits add primary key (id);
  end if;
end
$$;
