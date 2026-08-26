-- Beach Body Map — database schema
-- Run this in the Supabase SQL editor (Dashboard › SQL › New query).
--
-- There is deliberately no public.profiles table and no on_auth_user_created
-- trigger. A person here is only ever a person *at a beach* — their name, rank
-- and permissions all belong to the membership, and their username is unique
-- per beach rather than globally. A separate profile row would hold nothing
-- this app needs, so memberships reference auth.users directly.
--
-- It is idempotent and it is also the migration: `create table if not exists`
-- covers fresh projects, and the `alter table … add column if not exists`
-- blocks bring an older database up to this version. Running it twice is safe.
--
-- The shape follows how the app is actually used, which is not how it is
-- stored today. Everything currently lives in one localStorage blob written by
-- persist(); here it splits by who writes it and how often:
--
--   beaches   one row per customer. Config and pricing. Changes monthly.
--   zones     drawn shapes. A manager edits them in the spring, then rarely.
--   spots     one row per sun bed or parasol. STATUS CHANGES ALL DAY, from
--             several phones at once — which is exactly why it is a table of
--             rows and not a field in a document. Two staff marking two
--             different beds must never overwrite each other.
--   days      one row per beach per day: check-in counters and takings.
--   layouts   named snapshots of an arrangement, for putting the beach back.
--
-- Storing the whole beach as a single jsonb document would have been less
-- work and would have reintroduced the bug the server is meant to fix.

-- ---------------------------------------------------------------------------
-- Beaches — the tenant. One row per customer.
--
-- image_path points at an object in the `beach-images` storage bucket. map_w
-- and map_h are the pixel dimensions of that image; the app places every spot
-- as a fraction of them, so a beach can be re-photographed without moving a
-- single bed.
-- ---------------------------------------------------------------------------
create table if not exists public.beaches (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  name        text not null check (char_length(name) between 2 and 80),
  image_path  text,
  map_w       integer not null default 2600 check (map_w  between 100 and 20000),
  map_h       integer not null default 1950 check (map_h  between 100 and 20000),
  price       numeric(8,2) not null default 12 check (price     >= 0),
  umb_price   numeric(8,2) not null default 8  check (umb_price >= 0),
  currency    text not null default '€' check (char_length(currency) between 1 and 4),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Memberships — who may work which beach, and at what rank.
--
--   staff    the people on the sand: read the beach, change spot status,
--            count check-ins. Cannot move beds or change prices.
--   manager  staff, plus the layout, the zones and the pricing.
--   owner    manager, plus adding and removing people.
-- ---------------------------------------------------------------------------
create table if not exists public.memberships (
  beach_id   uuid not null references public.beaches(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null default 'staff' check (role in ('staff','manager','owner')),
  -- The name shown beside a status change. Kept here rather than joined from a
  -- profiles table, so this app owns every row it depends on.
  staff_name text not null default '',
  created_at timestamptz not null default now(),
  primary key (beach_id, user_id)
);

alter table public.memberships add column if not exists staff_name text not null default '';

create index if not exists memberships_user_idx on public.memberships(user_id);

-- Membership tests, used by nearly every policy below.
--
-- security definer so the policies can read memberships without the caller
-- needing a policy on memberships that reads memberships — which recurses and
-- takes the whole schema down with it.
create or replace function public.is_member(b uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $fn$
  select exists (
    select 1 from public.memberships m
    where m.beach_id = b and m.user_id = auth.uid()
  );
$fn$;

create or replace function public.has_rank(b uuid, ranks text[])
returns boolean
language sql
security definer
stable
set search_path = public
as $fn$
  select exists (
    select 1 from public.memberships m
    where m.beach_id = b and m.user_id = auth.uid() and m.role = any(ranks)
  );
$fn$;

-- ---------------------------------------------------------------------------
-- Zones — the drawn areas a beach is divided into.
-- points is an array of [x,y] pairs, each normalised 0..1 against the image.
-- ---------------------------------------------------------------------------
create table if not exists public.zones (
  id         uuid primary key default gen_random_uuid(),
  beach_id   uuid not null references public.beaches(id) on delete cascade,
  name       text not null default 'Zona',
  points     jsonb not null default '[]'::jsonb,
  seq        integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists zones_beach_idx on public.zones(beach_id);

-- ---------------------------------------------------------------------------
-- Spots — one row per sun bed or parasol.
--
-- nx and ny are fractions of the image, not pixels, so the layout survives a
-- new photograph at a different resolution.
--
-- status_at and status_by are what make a disagreement resolvable: when two
-- phones each think they know a bed's state, the later stamp wins and the app
-- can say who set it. Without them a conflict is just two opinions.
-- ---------------------------------------------------------------------------
create table if not exists public.spots (
  id         uuid primary key default gen_random_uuid(),
  beach_id   uuid not null references public.beaches(id) on delete cascade,
  code       text not null check (char_length(code) between 1 and 16),
  kind       text not null default 'bed' check (kind in ('bed','umbrella')),
  nx         numeric(9,6) not null check (nx between 0 and 1),
  ny         numeric(9,6) not null check (ny between 0 and 1),
  status     text not null default 'free'
             check (status in ('free','occupied','reserved','maintenance')),
  guest      text not null default '' check (char_length(guest) <= 80),
  status_at  timestamptz not null default now(),
  status_by  uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (beach_id, code)
);

create index if not exists spots_beach_idx on public.spots(beach_id);

-- Any change of status stamps itself. Moving a bed on the map does not.
create or replace function public.touch_spot_status()
returns trigger
language plpgsql
as $fn$
begin
  if new.status is distinct from old.status or new.guest is distinct from old.guest then
    new.status_at := now();
    new.status_by := auth.uid();
  end if;
  return new;
end;
$fn$;

drop trigger if exists on_spot_status on public.spots;
create trigger on_spot_status
  before update on public.spots
  for each row execute function public.touch_spot_status();

-- ---------------------------------------------------------------------------
-- Days — check-in counters and takings, one row per beach per day.
--
-- The counters are cumulative for the day and only ever go up, so a phone that
-- was offline for an hour can send what it counted and have it added rather
-- than overwrite what everyone else counted. That is what bump_day() below is
-- for; clients should not PATCH these columns directly.
-- ---------------------------------------------------------------------------
create table if not exists public.days (
  id          uuid primary key default gen_random_uuid(),
  beach_id    uuid not null references public.beaches(id) on delete cascade,
  day         date not null,
  ci_bed      integer not null default 0 check (ci_bed      >= 0),
  ci_umbrella integer not null default 0 check (ci_umbrella >= 0),
  peak_occ    integer not null default 0 check (peak_occ    >= 0),
  setup       jsonb   not null default '{}'::jsonb,
  closed_at   timestamptz,
  revenue     numeric(10,2),
  currency    text,
  total_spots integer,
  unique (beach_id, day)
);

create index if not exists days_beach_day_idx on public.days(beach_id, day desc);

-- Add to the day's counters without reading them first. Two phones checking
-- guests in at the same moment both count; neither clobbers the other.
create or replace function public.bump_day(
  b uuid, d date, bed_delta integer default 0, umb_delta integer default 0, occ integer default null
)
returns public.days
language plpgsql
security definer
set search_path = public
as $fn$
declare row public.days;
begin
  if not public.is_member(b) then
    raise exception 'not a member of this beach';
  end if;

  insert into public.days (beach_id, day, ci_bed, ci_umbrella, peak_occ)
  values (b, d, greatest(bed_delta,0), greatest(umb_delta,0), coalesce(occ,0))
  on conflict (beach_id, day) do update
    set ci_bed      = public.days.ci_bed      + greatest(bed_delta,0),
        ci_umbrella = public.days.ci_umbrella + greatest(umb_delta,0),
        -- a peak is a high-water mark, never a running value
        peak_occ    = greatest(public.days.peak_occ, coalesce(occ, 0))
  returning * into row;

  return row;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Layouts — named snapshots of an arrangement.
-- ---------------------------------------------------------------------------
create table if not exists public.layouts (
  id         uuid primary key default gen_random_uuid(),
  beach_id   uuid not null references public.beaches(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  data       jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists layouts_beach_idx on public.layouts(beach_id);

-- ---------------------------------------------------------------------------
-- Row level security.
--
-- Every table is scoped by membership. A customer cannot see another
-- customer's beach even if they guess its id, because every policy below
-- starts from "are you a member of this beach".
-- ---------------------------------------------------------------------------
alter table public.beaches     enable row level security;
alter table public.memberships enable row level security;
alter table public.zones       enable row level security;
alter table public.spots       enable row level security;
alter table public.days        enable row level security;
alter table public.layouts     enable row level security;

-- beaches
drop policy if exists beaches_read on public.beaches;
create policy beaches_read on public.beaches for select
  using (public.is_member(id));

drop policy if exists beaches_write on public.beaches;
create policy beaches_write on public.beaches for update
  using (public.has_rank(id, array['manager','owner']))
  with check (public.has_rank(id, array['manager','owner']));

-- Anyone signed in may create a beach; the trigger below makes them its owner,
-- so a new customer can get started without an administrator in the loop.
drop policy if exists beaches_create on public.beaches;
create policy beaches_create on public.beaches for insert
  with check (auth.uid() is not null);

create or replace function public.claim_new_beach()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  insert into public.memberships (beach_id, user_id, role)
  values (new.id, auth.uid(), 'owner')
  on conflict do nothing;
  return new;
end;
$fn$;

drop trigger if exists on_beach_created on public.beaches;
create trigger on_beach_created
  after insert on public.beaches
  for each row execute function public.claim_new_beach();

-- memberships: everyone sees who they work with; only an owner changes it.
drop policy if exists memberships_read on public.memberships;
create policy memberships_read on public.memberships for select
  using (public.is_member(beach_id));

drop policy if exists memberships_manage on public.memberships;
create policy memberships_manage on public.memberships for all
  using (public.has_rank(beach_id, array['owner']))
  with check (public.has_rank(beach_id, array['owner']));

-- zones and layouts: staff read, managers change.
drop policy if exists zones_read on public.zones;
create policy zones_read on public.zones for select using (public.is_member(beach_id));

drop policy if exists zones_manage on public.zones;
create policy zones_manage on public.zones for all
  using (public.has_rank(beach_id, array['manager','owner']))
  with check (public.has_rank(beach_id, array['manager','owner']));

drop policy if exists layouts_read on public.layouts;
create policy layouts_read on public.layouts for select using (public.is_member(beach_id));

drop policy if exists layouts_manage on public.layouts;
create policy layouts_manage on public.layouts for all
  using (public.has_rank(beach_id, array['manager','owner']))
  with check (public.has_rank(beach_id, array['manager','owner']));

-- spots: this is the split that matters.
--
-- Staff change status all day, which is the whole job. Only a manager may add,
-- delete or move a bed — so a busy afternoon cannot accidentally redraw the
-- beach. Enforced by a trigger, because a policy cannot say "these columns
-- only".
drop policy if exists spots_read on public.spots;
create policy spots_read on public.spots for select using (public.is_member(beach_id));

drop policy if exists spots_update on public.spots;
create policy spots_update on public.spots for update
  using (public.is_member(beach_id)) with check (public.is_member(beach_id));

drop policy if exists spots_manage on public.spots;
create policy spots_manage on public.spots for all
  using (public.has_rank(beach_id, array['manager','owner']))
  with check (public.has_rank(beach_id, array['manager','owner']));

create or replace function public.guard_spot_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if public.has_rank(new.beach_id, array['manager','owner']) then
    return new;
  end if;
  if new.code    is distinct from old.code
  or new.kind    is distinct from old.kind
  or new.nx      is distinct from old.nx
  or new.ny      is distinct from old.ny
  or new.beach_id is distinct from old.beach_id then
    raise exception 'only a manager can move or rename a spot';
  end if;
  return new;
end;
$fn$;

drop trigger if exists on_spot_guard on public.spots;
create trigger on_spot_guard
  before update on public.spots
  for each row execute function public.guard_spot_columns();

-- days: staff read and count. Writes go through bump_day(), which is security
-- definer, so no direct insert or update policy is granted.
drop policy if exists days_read on public.days;
create policy days_read on public.days for select using (public.is_member(beach_id));

drop policy if exists days_close on public.days;
create policy days_close on public.days for update
  using (public.has_rank(beach_id, array['manager','owner']))
  with check (public.has_rank(beach_id, array['manager','owner']));

-- ---------------------------------------------------------------------------
-- Realtime. Spots and days are what other phones need to hear about; the
-- layout is not, because the person changing it is the only one looking.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'spots'
  ) then
    alter publication supabase_realtime add table public.spots;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'days'
  ) then
    alter publication supabase_realtime add table public.days;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Storage — the aerial photograph of each beach.
--
-- Public-read, because the image is the map and every signed-in device loads
-- it constantly; a signed URL per load would cost a round trip on exactly the
-- connection this app is built to survive without. Nothing private is in the
-- picture. Writes are restricted to managers by the policies below.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('beach-images', 'beach-images', true)
on conflict (id) do nothing;

-- Objects are stored as <beach_id>/<filename>, so the first path segment says
-- which beach an upload belongs to.
drop policy if exists beach_images_write on storage.objects;
create policy beach_images_write on storage.objects for insert
  with check (
    bucket_id = 'beach-images'
    and public.has_rank(((storage.foldername(name))[1])::uuid, array['manager','owner'])
  );

drop policy if exists beach_images_update on storage.objects;
create policy beach_images_update on storage.objects for update
  using (
    bucket_id = 'beach-images'
    and public.has_rank(((storage.foldername(name))[1])::uuid, array['manager','owner'])
  );

-- ---------------------------------------------------------------------------
-- After running this once, create your first beach from the app's setup
-- screen. Whoever creates it becomes its owner, and can invite the rest of the
-- staff from there.
--
-- To add someone by hand instead:
--   insert into public.memberships (beach_id, user_id, role)
--   values ('<beach uuid>', '<user uuid from auth.users>', 'staff');
-- ---------------------------------------------------------------------------
