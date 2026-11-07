alter table public.order_followups
  add column if not exists message_log jsonb not null default '[]'::jsonb;

create index if not exists order_followups_follow_up_at_idx
  on public.order_followups (follow_up_at)
  where follow_up_at is not null;
