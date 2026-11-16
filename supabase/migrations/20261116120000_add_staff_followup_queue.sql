create table if not exists public.order_followups (
  order_id uuid primary key references public.orders(id) on delete cascade,
  workflow_status text not null default 'call_later',
  follow_up_at timestamptz not null default (now() + interval '2 hours'),
  updated_at timestamptz not null default now(),
  constraint order_followups_workflow_status_check check (workflow_status in ('call_later'))
);
create index if not exists order_followups_follow_up_at_idx
  on public.order_followups(follow_up_at) where workflow_status = 'call_later';
alter table public.order_followups enable row level security;
alter table public.staff_order_audit drop constraint if exists staff_order_audit_action_check;
alter table public.staff_order_audit add constraint staff_order_audit_action_check
  check (action in ('viewed','confirmed','cancelled','call_later','follow_up_completed'));
