begin;
-- Prevent self-service privilege escalation through public.profiles.
-- Existing administrator rows keep their current role.
alter table public.profiles
  alter column role set default 'customer';

alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check
  check (role in ('admin', 'customer'));

drop policy if exists "admin profiles" on public.profiles;

create policy "users can read own profile"
  on public.profiles
  for select
  to authenticated
  using (auth.uid() = id);

revoke insert, update, delete on table public.profiles from anon, authenticated;
grant select on table public.profiles to authenticated;
commit;
