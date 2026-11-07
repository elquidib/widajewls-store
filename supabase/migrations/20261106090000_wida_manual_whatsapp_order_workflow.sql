-- Wida manual WhatsApp order workflow. Apply only to the Wida development database.
create table if not exists public.order_followups (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  workflow_status text not null default 'waiting_confirmation'
    check (workflow_status in ('waiting_confirmation','confirmed','no_answer','call_later','cancelled','prepared','shipped','delivered','failed_returned')),
  message_opened_at timestamptz,
  message_sent_at timestamptz,
  follow_up_at timestamptz,
  workflow_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists order_followups_follow_up_at_idx on public.order_followups (follow_up_at) where follow_up_at is not null;
alter table public.order_followups enable row level security;
drop policy if exists "admin order followups" on public.order_followups;
create policy "admin order followups" on public.order_followups for all to authenticated
using ((select role from public.profiles where id = (select auth.uid())) = 'admin')
with check ((select role from public.profiles where id = (select auth.uid())) = 'admin');
grant select, insert, update, delete on public.order_followups to authenticated;
