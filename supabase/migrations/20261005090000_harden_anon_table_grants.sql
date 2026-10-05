-- Harden public API table grants: anon only needs read access to storefront data.
REVOKE ALL ON TABLE public.profiles,
  public.collections,
  public.products,
  public.product_collections,
  public.customers,
  public.orders,
  public.order_items,
  public.reviews,
  public.discounts,
  public.site_settings
FROM anon;

GRANT SELECT ON TABLE public.collections,
  public.products,
  public.product_collections,
  public.reviews,
  public.site_settings
TO anon;
