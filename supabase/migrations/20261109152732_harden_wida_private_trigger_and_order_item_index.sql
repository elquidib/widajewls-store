CREATE INDEX IF NOT EXISTS order_items_variant_id_idx
  ON public.order_items (variant_id);

REVOKE ALL ON FUNCTION private.restore_order_stock()
  FROM PUBLIC, anon, authenticated, service_role;
