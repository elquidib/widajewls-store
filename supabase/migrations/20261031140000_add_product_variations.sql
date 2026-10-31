create table if not exists public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  image_url text not null check (length(trim(image_url)) > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists product_variants_product_sort_idx
  on public.product_variants(product_id, sort_order, created_at);

alter table public.order_items
  add column if not exists variant_id uuid references public.product_variants(id) on delete set null,
  add column if not exists variant_name text,
  add column if not exists variant_image_url text;

alter table public.product_variants enable row level security;

drop policy if exists "public read active product variants" on public.product_variants;
create policy "public read active product variants"
on public.product_variants for select to anon
using (
  is_active = true
  and exists (
    select 1 from public.products p
    where p.id = product_variants.product_id
      and p.status = 'active' and p.hidden = false
  )
);

drop policy if exists "admin manage product variants" on public.product_variants;
create policy "admin manage product variants"
on public.product_variants for all to authenticated
using (
  exists (select 1 from public.profiles pr where pr.id = (select auth.uid()) and pr.role = 'admin')
)
with check (
  exists (select 1 from public.profiles pr where pr.id = (select auth.uid()) and pr.role = 'admin')
);

grant select on public.product_variants to anon, authenticated;
grant insert, update, delete on public.product_variants to authenticated;

-- Extend the existing COD transaction without changing its signature or discount logic.
do $$
declare
  v_def text;
  v_old text;
  v_new text;
begin
  select pg_get_functiondef(
    'public.place_cod_order(text,text,text,text,text,jsonb,text,text)'::regprocedure
  ) into v_def;

  v_old := '  v_product_id uuid;' || chr(10);
  v_new := v_old ||
    '  v_variant_id uuid;' || chr(10) ||
    '  v_variant_name text;' || chr(10) ||
    '  v_variant_image_url text;' || chr(10);
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD product variable declaration'; end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := 'count(distinct (x->>''product_id''))';
  v_new := 'count(distinct ((x->>''product_id'') || '':'' || coalesce(x->>''variant_id'','''')))';
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD duplicate-item validation'; end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '    v_qty := (v_item->>''quantity'')::integer;' || chr(10);
  v_new := '    v_variant_id := null;' || chr(10) ||
    '    v_variant_name := null;' || chr(10) ||
    '    v_variant_image_url := null;' || chr(10) || v_old;
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD quantity validation'; end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := '    IF v_stock < v_qty THEN';
  v_new := $insert$
    BEGIN
      v_variant_id := nullif(v_item->>'variant_id','')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'Invalid product option. Please select it again.';
    END;

    IF v_variant_id IS NOT NULL THEN
      SELECT pv.name, pv.image_url
      INTO v_variant_name, v_variant_image_url
      FROM public.product_variants pv
      WHERE pv.id = v_variant_id
        AND pv.product_id = v_product_id
        AND pv.is_active = true;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'The selected product option is no longer available.';
      END IF;
    ELSIF EXISTS (
      SELECT 1 FROM public.product_variants pv
      WHERE pv.product_id = v_product_id AND pv.is_active = true
    ) THEN
      RAISE EXCEPTION 'Please select an option for %.', v_name;
    END IF;

    IF v_stock < v_qty THEN$insert$;
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD stock validation'; end if;
  v_def := replace(v_def, v_old, v_new);

  v_old := $old$
    INSERT INTO public.order_items(
      order_id, product_id, product_name, unit_price, quantity, line_total
    )
    VALUES(v_order_id, v_product_id, v_name, v_price, v_qty, v_price * v_qty);$old$;
  v_new := $new$
    INSERT INTO public.order_items(
      order_id, product_id, product_name, unit_price, quantity, line_total,
      variant_id, variant_name, variant_image_url
    )
    VALUES(
      v_order_id, v_product_id, v_name, v_price, v_qty, v_price * v_qty,
      v_variant_id, v_variant_name, v_variant_image_url
    );$new$;
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD order-item insert'; end if;
  v_def := replace(v_def, v_old, v_new);


  v_old := $loop_old$
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;

    SELECT p.name, p.price INTO v_name, v_price
    FROM public.products p WHERE p.id = v_product_id;$loop_old$;
  v_new := $loop_new$
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_product_id := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::integer;
    v_variant_id := nullif(v_item->>'variant_id','')::uuid;
    v_variant_name := null;
    v_variant_image_url := null;
    IF v_variant_id IS NOT NULL THEN
      SELECT pv.name, pv.image_url
      INTO v_variant_name, v_variant_image_url
      FROM public.product_variants pv
      WHERE pv.id = v_variant_id AND pv.product_id = v_product_id AND pv.is_active = true;
    END IF;

    SELECT p.name, p.price INTO v_name, v_price
    FROM public.products p WHERE p.id = v_product_id;$loop_new$;
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD order-item loop'; end if;
  v_def := replace(v_def, v_old, v_new);

  execute v_def;
end
$$;
