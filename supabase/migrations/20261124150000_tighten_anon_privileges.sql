-- Limit anonymous API privileges to the public storefront read surface.
-- Checkout writes are performed by the place-cod-order Edge Function using
-- its server-side service role; the storefront does not write tables directly.

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM anon;

GRANT SELECT ON TABLE
  public.products,
  public.collections,
  public.product_collections,
  public.reviews,
  public.product_variants
TO anon;

-- Preserve the exact public site-settings fields used by the storefront.
-- Admin WhatsApp destination and Agadir-specific delivery fee stay private.
GRANT SELECT (
  id, store_name, logo_url, hero_desktop_url, hero_mobile_url,
  hero_title, hero_subtitle, hero_button_text, hero_button_url,
  announcement_text, whatsapp_number, shipping_fee, instagram_url,
  facebook_url, tiktok_url, primary_color, updated_at, story_image_url,
  story_desktop_url, story_mobile_url
) ON public.site_settings TO anon;

REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM anon;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;

-- Prevent future postgres-owned application objects from inheriting broad
-- anonymous privileges. Public RPCs must receive explicit grants per function.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;
