-- Per-variation pricing for Wida Jewls.
-- NULL means inherit the parent product's price.
ALTER TABLE public.product_variants
  ADD COLUMN IF NOT EXISTS price numeric(10,2)
  CHECK (price IS NULL OR price >= 0);

DO $$
DECLARE
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(
    'public.place_cod_order(text,text,text,text,text,jsonb,text,text)'::regprocedure
  ) INTO v_def;

  v_old := '  v_variant_image_url text;';
  v_new := '  v_variant_image_url text;
  v_variant_price numeric;';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate variant image declaration in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '    v_variant_image_url := null;
    v_qty := (v_item->>''quantity'')::integer;';
  v_new := '    v_variant_image_url := null;
    v_variant_price := null;
    v_qty := (v_item->>''quantity'')::integer;';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate variant reset in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '      SELECT pv.name, pv.image_url
      INTO v_variant_name, v_variant_image_url';
  v_new := '      SELECT pv.name, pv.image_url, pv.price
      INTO v_variant_name, v_variant_image_url, v_variant_price';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate variant lookup in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '      IF NOT FOUND THEN
        RAISE EXCEPTION ''The selected product option is no longer available.'';
      END IF;';
  v_new := '      IF NOT FOUND THEN
        RAISE EXCEPTION ''The selected product option is no longer available.'';
      END IF;
      v_price := coalesce(v_variant_price, v_price);';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate variant availability check in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '    v_qty := (v_item->>''quantity'')::integer;

    SELECT p.name, p.price INTO v_name, v_price
    FROM public.products p WHERE p.id = v_product_id;';
  v_new := '    v_qty := (v_item->>''quantity'')::integer;
    v_variant_id := nullif(v_item->>''variant_id'','''')::uuid;

    SELECT p.name, p.price INTO v_name, v_price
    FROM public.products p WHERE p.id = v_product_id;

    IF v_variant_id IS NOT NULL THEN
      SELECT coalesce(pv.price, v_price) INTO v_price
      FROM public.product_variants pv
      WHERE pv.id = v_variant_id AND pv.product_id = v_product_id AND pv.is_active = true;
    END IF;';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate order item price lookup in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '      nullif(v_item->>''variant_id'','''')::uuid,
      (SELECT pv.name FROM public.product_variants pv WHERE pv.id = nullif(v_item->>''variant_id'','''')::uuid AND pv.product_id = v_product_id),';
  v_new := '      v_variant_id,
      (SELECT pv.name FROM public.product_variants pv WHERE pv.id = v_variant_id AND pv.product_id = v_product_id),';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate variant order snapshot in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  v_old := '      (SELECT pv.image_url FROM public.product_variants pv WHERE pv.id = nullif(v_item->>''variant_id'','''')::uuid AND pv.product_id = v_product_id)';
  v_new := '      (SELECT pv.image_url FROM public.product_variants pv WHERE pv.id = v_variant_id AND pv.product_id = v_product_id)';
  IF position(v_old in v_def) = 0 THEN
    RAISE EXCEPTION 'Could not locate variant image snapshot in place_cod_order';
  END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE v_def;
END
$$;
