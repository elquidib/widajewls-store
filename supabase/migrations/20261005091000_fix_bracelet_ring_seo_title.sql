-- Correct the SEO title for the Bracelet & Ring product.
UPDATE public.products
SET seo_title = 'Hello Kitty-Inspired Bracelet & Ring Set | Wida Jewls',
    updated_at = now()
WHERE slug = 'hello-kitty-inspired-jewelry-set-bracelet-ring';
