-- Keep the production performance indexes reproducible in the repository.
CREATE INDEX IF NOT EXISTS order_items_order_id_idx
  ON public.order_items(order_id);
CREATE INDEX IF NOT EXISTS product_collections_collection_id_idx
  ON public.product_collections(collection_id);
CREATE INDEX IF NOT EXISTS orders_customer_id_idx
  ON public.orders(customer_id);
CREATE INDEX IF NOT EXISTS order_items_product_id_idx
  ON public.order_items(product_id);
CREATE INDEX IF NOT EXISTS cod_rate_limits_ip_request_at_idx
  ON private.cod_rate_limits(ip, request_at DESC);
CREATE INDEX IF NOT EXISTS reviews_product_id_idx
  ON public.reviews(product_id);
