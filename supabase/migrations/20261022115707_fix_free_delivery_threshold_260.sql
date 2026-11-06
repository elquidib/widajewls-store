-- Restore the production-recorded migration that raises free delivery from 160 DH to 260 DH.
-- The live/preview function may already contain the 260 DH rule because it was
-- previously applied manually or through a later schema change. In that case,
-- this migration is intentionally a no-op.

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(p.oid)
    INTO v_definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'place_cod_order'
    AND pg_get_function_identity_arguments(p.oid) =
      'p_customer_name text, p_phone text, p_city text, p_address text, p_notes text, p_items jsonb, p_idempotency_key text, p_discount_code text';

  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'place_cod_order function not found; migration aborted';
  END IF;

  IF position('IF v_subtotal >= 260 THEN' IN v_definition) > 0 THEN
    -- Already correct; do not rewrite the function.
    NULL;
  ELSIF position('IF v_subtotal >= 160 THEN' IN v_definition) > 0 THEN
    v_definition := replace(
      v_definition,
      'IF v_subtotal >= 160 THEN',
      'IF v_subtotal >= 260 THEN'
    );
    EXECUTE v_definition;
  ELSE
    RAISE EXCEPTION 'Neither the old 160 DH nor the expected 260 DH threshold was found; migration aborted without changes';
  END IF;
END $$;
