-- Find a Time: database setup.
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- Visitors never touch the tables directly; they go through the functions below,
-- which check the secret edit tokens. Tokens are never readable from the browser.

create table if not exists public.polls (
  id          text primary key,
  title       text not null check (char_length(title) between 1 and 120),
  dates       date[] not null check (cardinality(dates) between 1 and 21),
  start_hour  int  not null check (start_hour between 0 and 23),
  end_hour    int  not null check (end_hour between 1 and 24 and end_hour > start_hour),
  tz          text not null default 'Europe/Brussels',
  owner_token uuid not null,
  created_at  timestamptz not null default now()
);

create table if not exists public.responses (
  poll_id    text not null references public.polls(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 40),
  slots      text[] not null default '{}' check (cardinality(slots) <= 1500),
  token      uuid not null,
  updated_at timestamptz not null default now(),
  primary key (poll_id, name)
);

alter table public.polls     enable row level security;
alter table public.responses enable row level security;
revoke all on public.polls, public.responses from anon, authenticated;

-- Read a poll (without its owner token)
create or replace function public.get_poll(p_id text)
returns table (id text, title text, dates date[], start_hour int, end_hour int, tz text, created_at timestamptz)
language sql security definer set search_path = public stable as $$
  select id, title, dates, start_hour, end_hour, tz, created_at from polls where polls.id = p_id;
$$;

-- Read everyone's saved answers for a poll (without tokens)
create or replace function public.get_responses(p_poll text)
returns table (name text, slots text[], updated_at timestamptz)
language sql security definer set search_path = public stable as $$
  select name, slots, updated_at from responses where poll_id = p_poll order by updated_at;
$$;

-- Create a poll; returns its id. The caller keeps owner_token to edit it later.
create or replace function public.create_poll(p_title text, p_dates date[], p_start int, p_end int, p_tz text, p_owner_token uuid)
returns text language plpgsql security definer set search_path = public as $$
declare new_id text;
begin
  loop
    new_id := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
    exit when not exists (select 1 from polls where id = new_id);
  end loop;
  insert into polls (id, title, dates, start_hour, end_hour, tz, owner_token)
  values (new_id, trim(p_title), (select array_agg(d order by d) from (select distinct unnest(p_dates) d) s), p_start, p_end, coalesce(nullif(p_tz,''),'Europe/Brussels'), p_owner_token);
  return new_id;
end $$;

-- Edit a poll's name/days/hours (owner only)
create or replace function public.update_poll(p_id text, p_owner_token uuid, p_title text, p_dates date[], p_start int, p_end int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update polls set title = trim(p_title),
    dates = (select array_agg(d order by d) from (select distinct unnest(p_dates) d) s),
    start_hour = p_start, end_hour = p_end
  where id = p_id and owner_token = p_owner_token;
  if not found then raise exception 'not_owner'; end if;
end $$;

-- Save (create or overwrite) one person's availability.
-- A name is claimed by whoever saves it first; later saves must carry the same token.
create or replace function public.save_response(p_poll text, p_name text, p_slots text[], p_token uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare existing uuid; ts timestamptz := now();
begin
  if not exists (select 1 from polls where id = p_poll) then raise exception 'no_poll'; end if;
  select token into existing from responses where poll_id = p_poll and lower(name) = lower(trim(p_name));
  if existing is not null and existing <> p_token then raise exception 'name_taken'; end if;
  if existing is null then
    insert into responses (poll_id, name, slots, token, updated_at) values (p_poll, trim(p_name), coalesce(p_slots,'{}'), p_token, ts);
  else
    update responses set slots = coalesce(p_slots,'{}'), updated_at = ts
    where poll_id = p_poll and lower(name) = lower(trim(p_name));
  end if;
  return ts;
end $$;

-- Remove yourself from a poll
create or replace function public.delete_response(p_poll text, p_name text, p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from responses where poll_id = p_poll and lower(name) = lower(trim(p_name)) and token = p_token;
$$;

grant execute on function public.get_poll(text), public.get_responses(text),
  public.create_poll(text, date[], int, int, text, uuid),
  public.update_poll(text, uuid, text, date[], int, int),
  public.save_response(text, text, text[], uuid),
  public.delete_response(text, text, uuid)
to anon, authenticated;
