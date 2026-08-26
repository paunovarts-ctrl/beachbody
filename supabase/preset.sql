-- Beach Body Map — the opening preset
-- Run this AFTER permissions.sql. Idempotent; running it twice is safe.
--
-- Beds wander during a shift: a parasol gets carried two spots along, a lounger
-- is dragged into the shade. The next morning the beach should look the way it
-- is meant to look, not the way last night left it.
--
-- The preset is one row in `layouts` rather than a column on `beaches`, for a
-- permissions reason: writing to `beaches` needs the pricing capability, and
-- the person who sets the beach out in the morning is not the person who sets
-- prices. `layouts` is already governed by edit_layout, which is exactly who
-- should own this.

alter table public.layouts add column if not exists is_opening boolean not null default false;

-- One opening preset per beach. A partial unique index says that without
-- forbidding any number of ordinary saved layouts alongside it.
create unique index if not exists layouts_opening_idx
  on public.layouts(beach_id) where is_opening;
