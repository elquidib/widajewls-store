-- Add reversible storefront visibility control for products.
ALTER TABLE public.products
ADD COLUMN IF NOT EXISTS hidden boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS products_hidden_idx
ON public.products(hidden);
