-- Beach Body Map — accounts and permissions
-- Run this AFTER schema.sql, in the Supabase SQL editor.
--
-- Idempotent, like schema.sql. Running it twice is safe.
--
-- ---------------------------------------------------------------------------
-- Why there are no e-mail addresses here
--
-- Staff sign in with a username, because a seasonal worker on a beach does not
-- have a work e-mail and should not need one. GoTrue only does password auth
-- against an e-mail, so the app turns "ivan" into "ivan@bbm.local" before it
-- talks to the server. That address is never shown, never sent to, and never
-- leaves the project.
--
-- Two settings must match this, under Authentication › Providers › Email:
--   Confirm email        OFF   — nothing can confirm a .local address
--   Secure email change  OFF   — otherwise renaming a user waits on a mail
--
-- ---------------------------------------------------------------------------
-- Why permissions are columns and not just a role name
--
-- The owner hands out capabilities one at a time, so a rank is only a preset.
-- A worker gets the map and the beds and nothing else: they can carry a
-- parasol to a new spot and mark a bed occupied, and they cannot see what the
-- beach took today.
-- ---------------------------------------------------------------------------

alter table public.memberships add column if not exists username         text;
alter table public.memberships add column if not exists can_edit_layout  boolean not null default true;
alter table public.memberships add column if not exists can_set_status   boolean not null default true;
alter table public.memberships add column if not exists can_edit_zones   boolean not null default false;
alter table public.memberships add column if not exists can_see_money    boolean not null default false;
alter table public.memberships add column if not exists can_edit_prices  boolean not null default false;
alter table public.memberships add column if not exists can_manage_users boolean not null default false;

-- 'worker' replaces 'staff' as the name of the plain rank; the old value is
-- migrated so an existing project does not fail the new constraint.
alter table public.memberships drop constraint if exists memberships_role_check;
update public.memberships set role = 'worker' where role = 'staff';
alter table public.memberships alter column role set default 'worker';
alter table public.memberships
  add constraint memberships_role_check check (role in ('worker','manager','owner'));

-- A username is unique within a beach, not globally: two beaches may each
-- have an "ivan" and they are different people.
create unique index if not exists memberships_username_idx
  on public.memberships(beach_id, lower(username)) where username is not null;

-- ---------------------------------------------------------------------------
-- One test the policies can ask: may this person do this thing here?
--
-- An owner is always allowed, so revoking your own last permission cannot lock
-- you out of your own beach.
-- ---------------------------------------------------------------------------
create or replace function public.can(b uuid, p text)
returns boolean
language sql
security definer
stable
set search_path = public
as $fn$
  select exists (
    select 1 from public.memberships m
    where m.beach_id = b
      and m.user_id  = auth.uid()
      and (
        m.role = 'owner'
        or (p = 'edit_layout'  and m.can_edit_layout)
        or (p = 'set_status'   and m.can_set_status)
        or (p = 'edit_zones'   and m.can_edit_zones)
        or (p = 'see_money'    and m.can_see_money)
        or (p = 'edit_prices'  and m.can_edit_prices)
        or (p = 'manage_users' and m.can_manage_users)
      )
  );
$fn$;

-- ---------------------------------------------------------------------------
-- Policies, restated against capabilities.
-- ---------------------------------------------------------------------------

-- beaches: everyone working here reads it; prices need the pricing capability.
drop policy if exists beaches_write on public.beaches;
create policy beaches_write on public.beaches for update
  using (public.can(id, 'edit_prices'))
  with check (public.can(id, 'edit_prices'));

-- zones: drawing an area is a manager's job.
drop policy if exists zones_manage on public.zones;
create policy zones_manage on public.zones for all
  using (public.can(beach_id, 'edit_zones'))
  with check (public.can(beach_id, 'edit_zones'));

drop policy if exists layouts_manage on public.layouts;
create policy layouts_manage on public.layouts for all
  using (public.can(beach_id, 'edit_layout'))
  with check (public.can(beach_id, 'edit_layout'));

-- spots: a worker marks beds and moves furniture. Both are their actual job,
-- so both are on by default — and both are revocable.
drop policy if exists spots_update on public.spots;
create policy spots_update on public.spots for update
  using (public.can(beach_id, 'set_status') or public.can(beach_id, 'edit_layout'))
  with check (public.can(beach_id, 'set_status') or public.can(beach_id, 'edit_layout'));

drop policy if exists spots_manage on public.spots;
create policy spots_manage on public.spots for all
  using (public.can(beach_id, 'edit_layout'))
  with check (public.can(beach_id, 'edit_layout'));

-- The column guard now follows the layout capability rather than the rank.
create or replace function public.guard_spot_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if public.can(new.beach_id, 'edit_layout') then
    return new;
  end if;
  if new.code     is distinct from old.code
  or new.kind     is distinct from old.kind
  or new.nx       is distinct from old.nx
  or new.ny       is distinct from old.ny
  or new.beach_id is distinct from old.beach_id then
    raise exception 'you are not allowed to move or rename a spot';
  end if;
  return new;
end;
$fn$;

-- memberships: you may always read your own row — the app needs it to know
-- what to show you. Seeing the rest of the staff list is a capability.
drop policy if exists memberships_read on public.memberships;
create policy memberships_read on public.memberships for select
  using (user_id = auth.uid() or public.can(beach_id, 'manage_users'));

drop policy if exists memberships_manage on public.memberships;
create policy memberships_manage on public.memberships for all
  using (public.can(beach_id, 'manage_users'))
  with check (public.can(beach_id, 'manage_users'));

-- days: takings are money, so reading them is the money capability. The
-- counters still go up through bump_day() for anyone who may set status.
drop policy if exists days_read on public.days;
create policy days_read on public.days for select
  using (public.can(beach_id, 'see_money'));

drop policy if exists days_close on public.days;
create policy days_close on public.days for update
  using (public.can(beach_id, 'see_money'))
  with check (public.can(beach_id, 'see_money'));

-- bump_day only ever adds to counters, so a worker checking a guest in may
-- call it without being able to read what the day is worth.
--
-- Dropped rather than replaced: schema.sql declares it `returns public.days`
-- and this one returns void. CREATE OR REPLACE cannot change a return type —
-- it aborts, and in the SQL editor that rolls back this entire file.
drop function if exists public.bump_day(uuid, date, integer, integer, integer);

create function public.bump_day(
  b uuid, d date, bed_delta integer default 0, umb_delta integer default 0, occ integer default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.can(b, 'set_status') then
    raise exception 'you are not allowed to check guests in here';
  end if;

  insert into public.days (beach_id, day, ci_bed, ci_umbrella, peak_occ)
  values (b, d, greatest(bed_delta,0), greatest(umb_delta,0), coalesce(occ,0))
  on conflict (beach_id, day) do update
    set ci_bed      = public.days.ci_bed      + greatest(bed_delta,0),
        ci_umbrella = public.days.ci_umbrella + greatest(umb_delta,0),
        peak_occ    = greatest(public.days.peak_occ, coalesce(occ, 0));
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Adding staff.
--
-- The app signs the new account up through GoTrue like any other, which means
-- no service key ever reaches the browser. A fresh account has no membership
-- and RLS therefore shows it nothing at all — this function is what turns it
-- into a member of your beach, and only someone who may manage users can call
-- it.
-- ---------------------------------------------------------------------------
create or replace function public.add_member(
  b uuid, uname text, uid uuid, rank text default 'worker',
  p_layout boolean default true, p_status boolean default true,
  p_zones boolean default false, p_money boolean default false,
  p_prices boolean default false, p_users boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not public.can(b, 'manage_users') then
    raise exception 'you are not allowed to add people to this beach';
  end if;
  if rank not in ('worker','manager','owner') then
    raise exception 'unknown rank %', rank;
  end if;

  insert into public.memberships (
    beach_id, user_id, role, username, staff_name,
    can_edit_layout, can_set_status, can_edit_zones,
    can_see_money, can_edit_prices, can_manage_users
  ) values (
    b, uid, rank, lower(uname), uname,
    p_layout, p_status, p_zones, p_money, p_prices, p_users
  )
  on conflict (beach_id, user_id) do update
    set role = excluded.role,
        username = excluded.username,
        can_edit_layout  = excluded.can_edit_layout,
        can_set_status   = excluded.can_set_status,
        can_edit_zones   = excluded.can_edit_zones,
        can_see_money    = excluded.can_see_money,
        can_edit_prices  = excluded.can_edit_prices,
        can_manage_users = excluded.can_manage_users;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- The first owner.
--
-- This creates a NEW beach and makes the caller its owner. It does not check
-- whether they already have one — the app does that before calling, so setup
-- run twice adopts the existing beach instead of leaving empty ones behind.
--
-- Note that any signed-in account can call this, and sign-ups are open. That
-- is fine while the project is yours: a stranger who signs up gets an empty
-- beach of their own and can see nothing else. Before this is sold to anyone,
-- close sign-ups and hand out accounts from the People screen instead.
-- ---------------------------------------------------------------------------
create or replace function public.claim_beach(beach_name text, uname text)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  new_id uuid;
  slug_base text;
begin
  if auth.uid() is null then
    raise exception 'sign in first';
  end if;

  slug_base := regexp_replace(lower(coalesce(nullif(beach_name,''),'beach')), '[^a-z0-9]+', '-', 'g');
  slug_base := trim(both '-' from slug_base);
  if char_length(slug_base) < 2 then slug_base := 'beach'; end if;

  insert into public.beaches (slug, name)
  values (slug_base || '-' || substr(gen_random_uuid()::text, 1, 6), beach_name)
  returning id into new_id;

  insert into public.memberships (
    beach_id, user_id, role, username, staff_name,
    can_edit_layout, can_set_status, can_edit_zones,
    can_see_money, can_edit_prices, can_manage_users
  ) values (new_id, auth.uid(), 'owner', lower(uname), uname, true, true, true, true, true, true);

  return new_id;
end;
$fn$;

-- The insert policy on beaches is no longer needed: claim_beach is the only
-- way in, and it is security definer.
drop policy if exists beaches_create on public.beaches;
drop trigger if exists on_beach_created on public.beaches;

-- ---------------------------------------------------------------------------
-- After running this:
--   1. Authentication › Providers › Email — turn OFF "Confirm email" and
--      "Secure email change".
--   2. Open the app. It offers to set up the first owner; the defaults are
--      Admin / Admin1. Change that password from Users as soon as you are in.
-- ---------------------------------------------------------------------------
