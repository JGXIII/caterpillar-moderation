-- Caterpillar Moderation — Supabase schema
-- Run once in the Supabase SQL editor (project jkxxqojfualdmsvyaprz).
--
-- Security model:
--   • The app INSERTs anonymously (anon key) — devices submit data.
--   • Only YOU (an authenticated user you create in Auth → Users) can
--     SELECT everything, UPDATE, approve/reject via the dashboard.
--   • The app may SELECT approval status of ai_candidates (harmless),
--     so approvals flow back into Caterpillar automatically.

create table if not exists moderation_submissions (
  id uuid primary key,
  barcode text,
  food_name text not null,
  brand text,
  calories double precision,
  protein double precision,
  carbs double precision,
  fat double precision,
  serving_size double precision,
  country text,
  submitter_id uuid,
  label_photo_b64 text,          -- optional compressed label photo
  kind text default 'submission',-- submission | correction
  status text default 'pending', -- pending | approved | rejected
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists moderation_food_requests (
  id uuid primary key,
  food_name text not null,
  brand text,
  barcode text,
  request_count int default 1,
  status text default 'pending',
  created_at timestamptz default now()
);

create table if not exists moderation_ai_candidates (
  id uuid primary key,
  name text not null,
  brand text,
  barcode text,
  calories double precision,
  protein double precision,
  carbs double precision,
  fat double precision,
  fibre double precision,
  serving_size double precision,
  caffeine_mg double precision,
  source_query text,
  ai_confidence double precision,
  times_suggested int default 0,
  selection_count int default 0,
  approval_status text default 'pending',
  first_seen timestamptz default now(),
  last_seen timestamptz default now()
);

create table if not exists moderation_barcode_triage (
  id uuid primary key default gen_random_uuid(),
  barcode text,
  error_signature text,
  raw_response text,
  displayed_calories double precision,
  created_at timestamptz default now()
);

alter table moderation_submissions    enable row level security;
alter table moderation_food_requests  enable row level security;
alter table moderation_ai_candidates  enable row level security;
alter table moderation_barcode_triage enable row level security;

-- Devices may INSERT (and upsert-update their own ai_candidate counters)
create policy anon_insert_submissions on moderation_submissions
  for insert to anon with check (true);
create policy anon_insert_requests on moderation_food_requests
  for insert to anon with check (true);
create policy anon_insert_candidates on moderation_ai_candidates
  for insert to anon with check (true);
create policy anon_update_candidates on moderation_ai_candidates
  for update to anon using (true) with check (approval_status = approval_status);
create policy anon_insert_triage on moderation_barcode_triage
  for insert to anon with check (true);

-- Devices may read candidate approval statuses back
create policy anon_read_candidates on moderation_ai_candidates
  for select to anon using (true);

-- You (authenticated) can do everything
create policy auth_all_submissions on moderation_submissions
  for all to authenticated using (true) with check (true);
create policy auth_all_requests on moderation_food_requests
  for all to authenticated using (true) with check (true);
create policy auth_all_candidates on moderation_ai_candidates
  for all to authenticated using (true) with check (true);
create policy auth_all_triage on moderation_barcode_triage
  for all to authenticated using (true) with check (true);

-- ── Reach tracking (dashboard "% of active devices reached" column) ──
-- device_id is a random UUID generated once per install (App/
-- ModerationSyncService.swift) — never tied to a real identity, purely
-- lets us tell devices apart for propagation stats. Two tables:
--   • device_pings     — one row per device, "last synced at" (any sync,
--                        push or pull) — this is the ACTIVE-USER denominator.
--   • candidate_receipts — one row per (device, candidate) the device has
--                        actually pulled an APPROVED status for — the
--                        per-item numerator.
create table if not exists moderation_device_pings (
  device_id uuid primary key,
  last_seen_at timestamptz default now()
);

create table if not exists moderation_candidate_receipts (
  device_id uuid not null,
  candidate_id uuid not null,
  first_seen_at timestamptz default now(),
  primary key (device_id, candidate_id)
);

alter table moderation_device_pings       enable row level security;
alter table moderation_candidate_receipts enable row level security;

-- Devices may upsert their own rows; no anon SELECT — a device has no
-- legitimate reason to read reach stats for other devices.
create policy anon_upsert_pings on moderation_device_pings
  for insert to anon with check (true);
create policy anon_update_pings on moderation_device_pings
  for update to anon using (true) with check (true);
create policy anon_upsert_receipts on moderation_candidate_receipts
  for insert to anon with check (true);
create policy anon_update_receipts on moderation_candidate_receipts
  for update to anon using (true) with check (true);

create policy auth_all_pings on moderation_device_pings
  for all to authenticated using (true) with check (true);
create policy auth_all_receipts on moderation_candidate_receipts
  for all to authenticated using (true) with check (true);

-- Per-candidate reach against devices active in the last 7 days.
-- security_invoker: runs with the CALLER's RLS, not the view owner's — the
-- dashboard's authenticated role sees full data via auth_all_* above; anon
-- has no select policy on the base tables, so anon querying this view (it
-- isn't granted to anon at all — see grant below) would see nothing anyway.
create or replace view moderation_candidate_reach
with (security_invoker = true) as
select
  c.id as candidate_id,
  count(distinct r.device_id) filter (
    where p.last_seen_at > now() - interval '7 days'
  ) as reached_devices,
  (select count(distinct device_id) from moderation_device_pings
   where last_seen_at > now() - interval '7 days') as active_devices
from moderation_ai_candidates c
left join moderation_candidate_receipts r on r.candidate_id = c.id
left join moderation_device_pings p on p.device_id = r.device_id
group by c.id;

grant select on moderation_candidate_reach to authenticated;

-- ── Account sync (Sign in with Apple → cross-device / reinstall-proof data) ──
-- ONE table, JSON payload per category, keyed by (user_id, category). This is
-- a deliberate "cloud backup + restore" design, not live multi-device sync —
-- every category has its own union/max merge rule on the CLIENT (see
-- App/CloudSyncService.swift + AchievementManager.mergeCloud /
-- DashboardViewModel.mergeDayHistory) so progress can never be lost by a bad
-- merge order, regardless of which side (local vs cloud) is more current.
-- v1 categories: achievements, day_history, today. Profile/settings sync is
-- a deliberate fast-follow (see "Still needs" — it needs SwiftData access
-- this service doesn't have yet), not an oversight.
-- RLS is the real security boundary here: a row can only ever be read/
-- written by the Supabase-authenticated user it belongs to — this is real
-- per-user account data, unlike every other table in this file (which is
-- anonymous, device-scoped, and reviewed by you).
-- payload is TEXT (an already JSON-encoded string), not jsonb — this table
-- is always read/written whole by the app and never queried into from SQL,
-- so there's no benefit to jsonb's structure, and text sidesteps any
-- ambiguity about how a client SDK decodes a jsonb column that itself
-- contains an arbitrary nested document.
create table if not exists user_sync_data (
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null,     -- 'achievements' | 'day_history' | 'today'
  payload text not null,
  updated_at timestamptz default now(),
  primary key (user_id, category)
);

alter table user_sync_data enable row level security;

create policy user_owns_their_data on user_sync_data
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ── SECURITY FIX: moderator-only access to moderation tables ──
-- The auth_all_* policies above date from when the dashboard login was the
-- ONLY authenticated principal. Now that app users sign in with Apple,
-- THEY hold `authenticated` JWTs too — under the old policies any signed-in
-- app user could read/approve/delete moderation data via PostgREST.
-- Re-scope every moderator policy to the dashboard login's email.
-- ⚠️ REPLACE the email below with the EXACT email you log into the
-- moderation dashboard with, then run this whole block.

drop policy if exists auth_all_submissions on moderation_submissions;
drop policy if exists auth_all_requests    on moderation_food_requests;
drop policy if exists auth_all_candidates  on moderation_ai_candidates;
drop policy if exists auth_all_triage      on moderation_barcode_triage;
drop policy if exists auth_all_pings       on moderation_device_pings;
drop policy if exists auth_all_receipts    on moderation_candidate_receipts;

create policy moderator_all_submissions on moderation_submissions
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');
create policy moderator_all_requests on moderation_food_requests
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');
create policy moderator_all_candidates on moderation_ai_candidates
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');
create policy moderator_all_triage on moderation_barcode_triage
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');
create policy moderator_all_pings on moderation_device_pings
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');
create policy moderator_all_receipts on moderation_candidate_receipts
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');

-- ── Account deletion requests ──
-- Written ONLY by the account-deletion edge function (service role, which
-- bypasses RLS) so users can't spoof rows for other accounts. Deliberately
-- NO foreign key to auth.users: the row must survive as an audit record
-- after you delete the user. Read/managed by the moderator via the
-- dashboard's "Deletion Requests" tab.
create table if not exists account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  email text,
  status text default 'pending',   -- pending | done
  created_at timestamptz default now()
);

alter table account_deletion_requests enable row level security;

create policy moderator_all_deletions on account_deletion_requests
  for all to authenticated
  using ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com')
  with check ((select auth.jwt()->>'email') = 'JackKGrant@icloud.com');

-- ── Meal-scan photo storage (Pro only — see App/CloudSyncService.swift) ──
-- Private bucket; each user's photos live under their own folder
-- (meal-photos/{user_id}/{filename}) and the policy below hard-enforces
-- that a user can only ever touch their own folder — not just "logged in",
-- but specifically THEIR uid. This is a deliberate no-op for real users
-- right now: isPro has no StoreKit behind it yet, so nobody uploads
-- anything until that ships (see project memory "Still needs").
insert into storage.buckets (id, name, public)
values ('meal-photos', 'meal-photos', false)
on conflict (id) do nothing;

create policy meal_photos_owner_all on storage.objects
  for all to authenticated
  using (
    bucket_id = 'meal-photos'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  )
  with check (
    bucket_id = 'meal-photos'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
  );
