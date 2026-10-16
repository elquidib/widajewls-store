begin;
-- Enforce product hiding at the database boundary, not only in storefront JavaScript.
drop policy if exists "public read active products" on public.products;
create policy "public read active visible products"
  on public.products
  for select
  to anon
  using (status = 'active' and hidden = false);

drop policy if exists "public read product collections" on public.product_collections;
create policy "public read visible product collections"
  on public.product_collections
  for select
  to anon
  using (
    exists (
      select 1
      from public.products p
      where p.id = product_collections.product_id
        and p.status = 'active'
        and p.hidden = false
    )
    and exists (
      select 1
      from public.collections c
      where c.id = product_collections.collection_id
        and c.status = 'active'
    )
  );
commit;
