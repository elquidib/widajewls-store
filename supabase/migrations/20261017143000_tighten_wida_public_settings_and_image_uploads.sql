-- Restrict the private admin WhatsApp destination from anonymous reads.
REVOKE SELECT (admin_whatsapp_number) ON public.site_settings FROM anon;

-- Product images are served publicly, but uploads should be WebP only and capped at 3 MiB.
UPDATE storage.buckets
SET allowed_mime_types = ARRAY['image/webp']::text[],
    file_size_limit = 3145728
WHERE id = 'product-images';
