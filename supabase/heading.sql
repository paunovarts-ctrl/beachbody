-- Beach Body Map — which way a bed faces
-- Run this AFTER permissions.sql. Idempotent; running it twice is safe.
--
-- Loungers are not dots. A row along the shore faces the water, the ones by
-- the wall face out, and a parasol between them belongs at the angle the row
-- sits at. Storing a heading lets the map show the beach as it actually looks
-- rather than as a scatter of identical pins.
--
-- Degrees clockwise from north, 0-359. A bed at 0 faces up the image.

alter table public.spots add column if not exists heading smallint not null default 0;

alter table public.spots drop constraint if exists spots_heading_check;
alter table public.spots add constraint spots_heading_check check (heading between 0 and 359);

-- ---------------------------------------------------------------------------
-- Turning a bed is arranging the beach, so it belongs to edit_layout — the
-- same permission as moving one. Without this line the column guard ignores
-- heading, and someone allowed only to change a bed's status could quietly
-- spin the whole row.
-- ---------------------------------------------------------------------------
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
  or new.heading  is distinct from old.heading
  or new.beach_id is distinct from old.beach_id then
    raise exception 'you are not allowed to move, turn or rename a spot';
  end if;
  return new;
end;
$fn$;
