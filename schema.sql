-- Pull Up: database setup (v2: profiles, plans, joins, group chat, reports)
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run more than once. WARNING: running it again erases all profiles, plans and chats.

drop table if exists public.messages cascade;
drop table if exists public.reports cascade;
drop table if exists public.going cascade;
drop table if exists public.activities cascade;
drop table if exists public.profiles cascade;
drop function if exists public.is_member(uuid);
drop function if exists public.check_join();
drop function if exists public.is_msu();

-- Only signed-in users with an @msu.edu email count as members.
create function public.is_msu()
returns boolean language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', '') ilike '%@msu.edu'
$$;

-- One profile per person
create table public.profiles (
  id         uuid primary key default auth.uid() references auth.users on delete cascade,
  name       text not null check (char_length(name) between 1 and 40),
  year       text check (year in ('Freshman','Sophomore','Junior','Senior','Grad')),
  major      text check (major is null or char_length(major) <= 60),
  bio        text check (bio is null or char_length(bio) <= 200),
  interests  text[] not null default '{}' check (cardinality(interests) <= 7),
  created_at timestamptz not null default now()
);

-- Plans people post
create table public.activities (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (char_length(title) between 1 and 80),
  cat        text not null check (cat in ('Gym','Study','Food','Sports','Games','Explore','Other')),
  place      text not null check (char_length(place) between 1 and 60),
  starts_at  timestamptz not null,
  cap        int  not null check (cap between 1 and 50),
  note       text check (note is null or char_length(note) <= 200),
  host       uuid not null default auth.uid() references public.profiles on delete cascade,
  hidden     boolean not null default false,  -- set to true in the Table Editor to take a post down
  created_at timestamptz not null default now()
);
create index activities_starts_at on public.activities (starts_at);

-- Who is going to what
create table public.going (
  activity_id uuid not null references public.activities on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (activity_id, user_id)
);

-- Group chat for each plan (only the host and people going can read or write)
create table public.messages (
  id          bigint generated always as identity primary key,
  activity_id uuid not null references public.activities on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  body        text not null check (char_length(body) between 1 and 500),
  created_at  timestamptz not null default now()
);
create index messages_activity on public.messages (activity_id, created_at);

-- Reports (only you can read these, in the Table Editor)
create table public.reports (
  id          bigint generated always as identity primary key,
  activity_id uuid not null references public.activities on delete cascade,
  reporter    uuid not null default auth.uid() references auth.users on delete cascade,
  reason      text check (reason is null or char_length(reason) <= 300),
  created_at  timestamptz not null default now(),
  unique (activity_id, reporter)
);

-- Is the current user the host of, or going to, this plan?
create function public.is_member(aid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from activities where id = aid and host = auth.uid())
      or exists (select 1 from going where activity_id = aid and user_id = auth.uid())
$$;

-- Stop people joining full, past, hidden or their own plans
create function public.check_join()
returns trigger language plpgsql security definer set search_path = public as $$
declare a activities%rowtype;
begin
  select * into a from activities where id = new.activity_id for update;
  if not found or a.hidden then raise exception 'That plan is no longer available'; end if;
  if a.host = new.user_id then raise exception 'You are hosting this plan'; end if;
  if a.starts_at < now() - interval '2 hours' then raise exception 'That plan already happened'; end if;
  if (select count(*) from going where activity_id = new.activity_id) >= a.cap then
    raise exception 'That plan is full';
  end if;
  return new;
end $$;
create trigger going_check before insert on public.going
  for each row execute function public.check_join();

-- Security rules
alter table public.profiles   enable row level security;
alter table public.activities enable row level security;
alter table public.going      enable row level security;
alter table public.messages   enable row level security;
alter table public.reports    enable row level security;

create policy "members read profiles" on public.profiles for select to authenticated using (public.is_msu());
create policy "create own profile"    on public.profiles for insert to authenticated with check (public.is_msu() and id = auth.uid());
create policy "edit own profile"      on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "members read plans" on public.activities for select to authenticated using (public.is_msu() and (not hidden or host = auth.uid()));
create policy "post own plans"     on public.activities for insert to authenticated with check (public.is_msu() and host = auth.uid() and not hidden);
create policy "delete own plans"   on public.activities for delete to authenticated using (host = auth.uid());

create policy "members read going" on public.going for select to authenticated using (public.is_msu());
create policy "join as yourself"   on public.going for insert to authenticated with check (public.is_msu() and user_id = auth.uid());
create policy "leave as yourself"  on public.going for delete to authenticated using (user_id = auth.uid());

create policy "group reads chat"  on public.messages for select to authenticated using (public.is_msu() and public.is_member(activity_id));
create policy "group writes chat" on public.messages for insert to authenticated with check (public.is_msu() and user_id = auth.uid() and public.is_member(activity_id));

create policy "members report" on public.reports for insert to authenticated with check (public.is_msu() and reporter = auth.uid());

grant select, insert, update on public.profiles to authenticated;
grant select, insert, delete on public.activities to authenticated;
grant select, insert, delete on public.going to authenticated;
grant select, insert on public.messages to authenticated;
grant insert on public.reports to authenticated;

-- Live updates
alter publication supabase_realtime add table public.activities, public.going, public.messages;
