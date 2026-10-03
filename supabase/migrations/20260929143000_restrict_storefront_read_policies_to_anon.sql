-- Restrict storefront read policies to anonymous visitors only.
-- The admin policies remain on authenticated users, avoiding duplicate permissive-policy evaluation.
drop policy if exists "public read active collections" on public.collections;
create policy "public read active collections" on public.collections
  for select to anon
  using (status = 'active');

drop policy if exists "public read product collections" on public.product_collections;
create policy "public read product collections" on public.product_collections
  for select to anon
  using (
    exists (select 1 from public.products p where p.id = product_collections.product_id and p.status = 'active')
    and exists (select 1 from public.collections c where c.id = product_collections.collection_id and c.status = 'active')
  );

drop policy if exists "public read active products" on public.products;
create policy "public read active products" on public.products
  for select to anon
  using (status = 'active');

drop policy if exists "public read approved reviews" on public.reviews;
create policy "public read approved reviews" on public.reviews
  for select to anon
  using (approved = true);

drop policy if exists "public read site settings" on public.site_settings;
create policy "public read site settings" on public.site_settings
  for select to anon
  using (true);
