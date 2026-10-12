-- Wida Jewls delivery-sheet integration.
-- Credentials are only readable by the service role, never by storefront/admin browser clients.
alter table public.orders
  add column if not exists delivery_sheet_exported_at timestamptz,
  add column if not exists delivery_sheet_sync_error text;

create table if not exists public.integration_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

alter table public.integration_settings enable row level security;
revoke all on table public.integration_settings from anon, authenticated;
grant all on table public.integration_settings to service_role;
