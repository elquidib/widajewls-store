do $$
declare
  v_def text;
  v_old text := '    IF v_stock < v_qty THEN';
  v_new text := $check$
    IF v_stock < (
      SELECT coalesce(sum((x->>'quantity')::integer),0)
      FROM jsonb_array_elements(p_items) AS x
      WHERE x->>'product_id' = v_product_id::text
    ) THEN$check$;
begin
  select pg_get_functiondef(
    'public.place_cod_order(text,text,text,text,text,jsonb,text,text)'::regprocedure
  ) into v_def;
  if position(v_old in v_def) = 0 then raise exception 'Could not locate COD stock check'; end if;
  execute replace(v_def, v_old, v_new);
end
$$;
