-- Grant anonymous storefront access only to public site settings.
-- In particular, do not expose the admin WhatsApp destination to anonymous clients.
REVOKE SELECT ON public.site_settings FROM anon;
GRANT SELECT (
  id, store_name, announcement_text, shipping_fee, facebook_url,
  hero_button_text, hero_button_url, hero_desktop_url, hero_mobile_url,
  hero_subtitle, hero_title, instagram_url, logo_url, primary_color,
  story_desktop_url, story_image_url, story_mobile_url, tiktok_url,
  updated_at, whatsapp_number
) ON public.site_settings TO anon;

-- Product images are publicly served, but uploads are WebP-only and capped at 3 MiB.
UPDATE storage.buckets
SET allowed_mime_types = ARRAY['image/webp']::text[],
    file_size_limit = 3145728
WHERE id = 'product-images';
