-- Коло добрих екосправ — схема
-- 101 курінь УСП «Карпатські Вовки»
--
--   createdb ekokolo
--   psql ekokolo -f db/schema.sql

begin;

-- ──────────────── Рої ────────────────

create table if not exists roi (
  id         bigint generated always as identity primary key,
  name       text   not null check (length(btrim(name)) between 1 and 24),
  code       text   not null unique check (code ~ '^[A-Z0-9]{4}$'),
  test       boolean not null default false,
  created_at timestamptz not null default now()
);

-- ──────────────── новаки ────────────────
-- codes — jsonb-масив ідентифікаторів справ ("d1", "d57").
-- cnt рахується базою, тож розійтися з codes не може.

create table if not exists novak (
  id         bigint generated always as identity primary key,
  roi_id     bigint not null references roi(id) on delete cascade,
  nick       text   not null check (length(btrim(nick)) between 1 and 24),
  nick_key   text   not null,
  codes      jsonb  not null default '[]'::jsonb
               check (jsonb_typeof(codes) = 'array'
                      and jsonb_array_length(codes) <= 200),
  cnt        integer generated always as (jsonb_array_length(codes)) stored,
  updated_at timestamptz not null default now(),
  unique (roi_id, nick_key)
);

create index if not exists novak_roi_idx on novak (roi_id);

-- ──────────────── відгуки ────────────────
-- Виховники оцінюють справи, поки грають у тестовому Рої.
-- deed = null — відгук про гру загалом; таких може бути скільки завгодно.
-- На справу — один рядок від виховника, оновлюється. title — назва справи
-- на момент відгуку, бо тексти після правок зміняться.

create table if not exists vidguk (
  id         bigint generated always as identity primary key,
  roi_id     bigint not null references roi(id) on delete cascade,
  nick       text   not null check (length(btrim(nick)) between 1 and 24),
  nick_key   text   not null,
  deed       text   check (deed ~ '^d[0-9]{1,3}$'),
  title      text   not null default '' check (length(title) <= 80),
  mark       text   check (mark in ('ok', 'hard', 'fix')),
  note       text   not null default '' check (length(note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (mark is not null or length(btrim(note)) > 0),
  unique (roi_id, nick_key, deed)
);

-- ──────────────── табло ────────────────
-- Тестові Рої не показуються.

create or replace view board as
select r.name                            as grp,
       coalesce(sum(n.cnt), 0)::integer  as sum,
       count(n.id)::integer              as n
from roi r
left join novak n on n.roi_id = r.id
where not r.test
group by r.id, r.name;

commit;
