BEGIN;

-- Convert historical Moroccan +212 numbers into the canonical 10-digit local format.
UPDATE public.orders
SET phone = '0' || substring(regexp_replace(phone,'[^0-9]','','g') from 4)
WHERE regexp_replace(coalesce(phone,''),'[^0-9]','','g') ~ '^212[67][0-9]{8}$';

UPDATE public.customers
SET phone = '0' || substring(regexp_replace(phone,'[^0-9]','','g') from 4),
    phone_normalized = CASE
      WHEN regexp_replace(coalesce(phone_normalized,''),'[^0-9]','','g') ~ '^212[67][0-9]{8}$'
        THEN '0' || substring(regexp_replace(phone_normalized,'[^0-9]','','g') from 4)
      ELSE phone_normalized
    END
WHERE regexp_replace(coalesce(phone,''),'[^0-9]','','g') ~ '^212[67][0-9]{8}$';

ALTER TABLE public.orders ADD CONSTRAINT orders_phone_moroccan_local_chk CHECK (phone ~ '^0[67][0-9]{8}$') NOT VALID;
ALTER TABLE public.orders VALIDATE CONSTRAINT orders_phone_moroccan_local_chk;
ALTER TABLE public.customers ADD CONSTRAINT customers_phone_moroccan_local_chk CHECK (phone ~ '^0[67][0-9]{8}$') NOT VALID;
ALTER TABLE public.customers VALIDATE CONSTRAINT customers_phone_moroccan_local_chk;
ALTER TABLE public.customers ADD CONSTRAINT customers_phone_normalized_moroccan_local_chk CHECK (phone_normalized IS NULL OR phone_normalized ~ '^0[67][0-9]{8}$') NOT VALID;
ALTER TABLE public.customers VALIDATE CONSTRAINT customers_phone_normalized_moroccan_local_chk;

-- Keep the database RPC itself canonical, not just the storefront and Edge Function.
DO $migration$
DECLARE
  v_definition text;
  v_old text := $old$  IF v_digits ~ '^212[567][0-9]{8}$' THEN
    v_phone := '+' || v_digits;
  ELSIF v_digits ~ '^0[567][0-9]{8}$' THEN
    v_phone := '+212' || substring(v_digits from 2);
  ELSIF v_digits ~ '^[567][0-9]{8}$' THEN
    v_phone := '+212' || v_digits;
  ELSE
    RAISE EXCEPTION 'Please enter a valid Moroccan phone number.';
  END IF;$old$;
  v_new text := $new$  IF v_digits ~ '^0[67][0-9]{8}$' THEN
    v_phone := v_digits;
  ELSE
    RAISE EXCEPTION 'Please enter a valid Moroccan mobile number starting with 06 or 07 (10 digits).';
  END IF;$new$;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='place_cod_order'
  LIMIT 1;
  IF v_definition IS NULL OR position(v_old in v_definition)=0 THEN
    RAISE EXCEPTION 'Could not locate the existing phone validation logic in place_cod_order.';
  END IF;
  v_definition := replace(v_definition,v_old,v_new);
  EXECUTE v_definition;
END;
$migration$;

COMMIT;