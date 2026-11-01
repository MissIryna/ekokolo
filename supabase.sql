-- Коло добрих екосправ — схема бази
-- 101 курінь УСП «Карпатські Вовки»
--
-- Виконати один раз у Supabase: SQL Editor → New query → вставити → Run.

-- ──────────────── рої ────────────────

create table if not exists public.roi (
  id          bigint generated always as identity primary key,
  name        text not null,
  code        text not null unique,
  test        boolean not null default false,
  created_at  timestamptz not null default now()
);

-- ──────────────── новаки ────────────────

create table if not exists public.novak (
  id          bigint generated always as identity primary key,
  roi_id      bigint not null references public.roi(id) on delete cascade,
  nick        text not null,
  nick_key    text not null,
  codes       jsonb not null default '[]'::jsonb,
  cnt         integer not null default 0,
  updated_at  timestamptz not null default now(),
  unique (roi_id, nick_key)
);

create index if not exists novak_roi_idx on public.novak (roi_id);

-- ──────────────── табло ────────────────
-- security_invoker: подання дотримується тих самих правил доступу,
-- що й таблиці під ним, а не прав власника.

create or replace view public.board
with (security_invoker = on) as
select
  r.id                               as roi_id,
  r.name                             as grp,
  coalesce(sum(n.cnt), 0)::integer   as sum,
  count(n.id)::integer               as n
from public.roi r
left join public.novak n on n.roi_id = r.id
where r.test = false
group by r.id, r.name;

-- ──────────────── доступ ────────────────
-- Гра працює без входу: будь-хто, хто має адресу сайту, може
-- створити рій, приєднатися й записати свій поступ. Це свідомий
-- вибір — восьмирічні не заводять облікових записів.

alter table public.roi   enable row level security;
alter table public.novak enable row level security;

drop policy if exists roi_read   on public.roi;
drop policy if exists roi_write  on public.roi;
drop policy if exists nov_read   on public.novak;
drop policy if exists nov_insert on public.novak;
drop policy if exists nov_update on public.novak;

create policy roi_read   on public.roi   for select using (true);
create policy roi_write  on public.roi   for insert with check (true);

create policy nov_read   on public.novak for select using (true);
create policy nov_insert on public.novak for insert with check (true);
create policy nov_update on public.novak for update using (true) with check (true);

-- Навмисно немає політик на delete: видалити рядок через сайт
-- неможливо, тільки руками в Supabase.

grant usage on schema public to anon;
grant select, insert         on public.roi   to anon;
grant select, insert, update on public.novak to anon;
grant select                 on public.board to anon;
