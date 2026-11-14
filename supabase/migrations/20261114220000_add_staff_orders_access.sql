alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('admin','staff','customer'));

create table if not exists public.staff_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9._-]{3,24}$'),
  display_name text not null check (char_length(trim(display_name)) between 1 and 80),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.staff_accounts enable row level security;
drop policy if exists "admin manage staff accounts" on public.staff_accounts;
create policy "admin manage staff accounts" on public.staff_accounts
  for all to authenticated
  using ((select role from public.profiles where id=(select auth.uid()))='admin')
  with check ((select role from public.profiles where id=(select auth.uid()))='admin');

create table if not exists public.staff_order_audit (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  staff_user_id uuid references auth.users(id) on delete set null,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null check (action in ('viewed','confirmed','cancelled','call_later')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists staff_order_audit_order_created_idx on public.staff_order_audit(order_id, created_at desc);
alter table public.staff_order_audit enable row level security;
drop policy if exists "admin read staff order audit" on public.staff_order_audit;
create policy "admin read staff order audit" on public.staff_order_audit
  for select to authenticated
  using ((select role from public.profiles where id=(select auth.uid()))='admin');

comment on table public.staff_accounts is 'Staff usernames and activation state. PINs are stored only as Supabase Auth password hashes.';
comment on table public.staff_order_audit is 'Audit history for staff order handling actions.';
