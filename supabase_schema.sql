-- ============================================================
-- Joker (Джокер) — схема Supabase
-- Вставить целиком в Supabase → SQL Editor → Run
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- Профили игроков (ключ — Yandex ID, без Supabase Auth) ----------
create table if not exists profiles (
  yandex_id       text primary key,
  display_name    text not null default 'Игрок',
  coins           bigint not null default 0,
  total_score     bigint not null default 0,
  equipped_skin_id text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ---------- Магазин скинов ----------
create table if not exists skins (
  id            text primary key,
  name          text not null,
  description   text,
  price_coins   integer not null default 0,
  is_default    boolean not null default false
);

create table if not exists user_skins (
  yandex_id     text not null references profiles(yandex_id) on delete cascade,
  skin_id       text not null references skins(id) on delete cascade,
  purchased_at  timestamptz not null default now(),
  primary key (yandex_id, skin_id)
);

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fk_equipped_skin'
  ) then
    alter table profiles
      add constraint fk_equipped_skin
      foreign key (equipped_skin_id) references skins(id);
  end if;
end $$;

-- ---------- Денежный журнал (для аудита — откуда взялись/куда делись монеты) ----------
create table if not exists coin_transactions (
  id          bigint generated always as identity primary key,
  yandex_id   text not null references profiles(yandex_id) on delete cascade,
  amount      bigint not null,           -- может быть отрицательным
  reason      text not null,             -- 'stake_settle' | 'skin_purchase' | 'daily_bonus' | 'jackpot' | 'league_reward' | 'admin'
  meta        jsonb not null default '{}',
  created_at  timestamptz not null default now()
);

-- ---------- Сезоны / лиги (день / неделя / месяц) ----------
create table if not exists seasons (
  id           uuid primary key default gen_random_uuid(),
  period_type  text not null check (period_type in ('daily','weekly','monthly')),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  is_active    boolean not null default true
);

create table if not exists season_scores (
  season_id   uuid not null references seasons(id) on delete cascade,
  yandex_id   text not null references profiles(yandex_id) on delete cascade,
  score       bigint not null default 0,
  primary key (season_id, yandex_id)
);

-- ---------- Джекпот месяца ----------
create table if not exists jackpot_pool (
  id             uuid primary key default gen_random_uuid(),
  month          date not null,           -- первое число месяца, напр. 2026-09-01
  pool_coins     bigint not null default 0,
  distributed    boolean not null default false
);

-- ---------- Игровые столы (для мультиплеера и ставок) ----------
-- Ставки: фиксированная лестница на ОДНУ пульку, сессия = всегда 4 пульки.
-- Игрок вносит stake_per_pulka × 4 при входе за стол.
create table if not exists game_tables (
  id                uuid primary key default gen_random_uuid(),
  status            text not null default 'waiting' check (status in ('waiting','playing','finished')),
  stake_per_pulka   integer not null default 0
    check (stake_per_pulka in (0,100,200,400,800,1600,3200,6400,12800,25600,51200)),
  pulkas_total       int not null default 4,
  mode              text not null default 'nines_short', -- ставки всегда на формате из 4 пулек
  created_at        timestamptz not null default now(),
  finished_at       timestamptz
);

create table if not exists table_players (
  table_id      uuid not null references game_tables(id) on delete cascade,
  seat          int not null check (seat between 0 and 3),
  yandex_id     text not null references profiles(yandex_id) on delete cascade,
  is_bot        boolean not null default false, -- true, если это место сейчас доигрывает бот
  last_seen_at  timestamptz not null default now(), -- обновляется клиентом при активности игрока
  primary key (table_id, seat)
);

-- ---------- История сыгранных раздач (для таблицы результатов) ----------
create table if not exists game_history (
  id          uuid primary key default gen_random_uuid(),
  table_id    uuid references game_tables(id) on delete set null,
  pulka_num   int not null,
  round_idx   int not null,
  round_size  int not null,
  results     jsonb not null,  -- [{yandex_id, bid, took, pts}, ...] по всем 4 игрокам
  created_at  timestamptz not null default now()
);

-- ============================================================
-- Row Level Security
-- Клиент подключается anon-ключом — прямые UPDATE/INSERT монет
-- запрещены, всё проходит только через функции ниже (security definer).
-- ============================================================

alter table profiles enable row level security;
alter table skins enable row level security;
alter table user_skins enable row level security;
alter table coin_transactions enable row level security;
alter table seasons enable row level security;
alter table season_scores enable row level security;
alter table jackpot_pool enable row level security;
alter table game_tables enable row level security;
alter table table_players enable row level security;
alter table game_history enable row level security;

-- Публичное чтение (лидерборды, магазин, столы) разрешено всем.
drop policy if exists "public read profiles" on profiles;
create policy "public read profiles" on profiles for select using (true);
drop policy if exists "public read skins" on skins;
create policy "public read skins" on skins for select using (true);
drop policy if exists "public read user_skins" on user_skins;
create policy "public read user_skins" on user_skins for select using (true);
drop policy if exists "public read seasons" on seasons;
create policy "public read seasons" on seasons for select using (true);
drop policy if exists "public read season_scores" on season_scores;
create policy "public read season_scores" on season_scores for select using (true);
drop policy if exists "public read jackpot" on jackpot_pool;
create policy "public read jackpot" on jackpot_pool for select using (true);
drop policy if exists "public read tables" on game_tables;
create policy "public read tables" on game_tables for select using (true);
drop policy if exists "public read table_players" on table_players;
create policy "public read table_players" on table_players for select using (true);
drop policy if exists "public read history" on game_history;
create policy "public read history" on game_history for select using (true);

-- Прямая запись клиентом ЗАПРЕЩЕНА — никаких insert/update policy для
-- profiles/coin_transactions/user_skins и т.д. Изменения только через
-- rpc-функции ниже, которые сами проверяют условия и пишут атомарно.

-- game_tables / table_players — это координация лобби и посадки за стол
-- (кто где сидит), а не деньги, поэтому для них разрешена прямая запись
-- клиентом (нужна для матчмейкинга без отдельного сервера). Монеты всё
-- равно двигаются только через fn_charge_stake_entry / fn_settle_stake_table.
drop policy if exists "public insert tables" on game_tables;
create policy "public insert tables" on game_tables for insert with check (true);
drop policy if exists "public update tables" on game_tables;
create policy "public update tables" on game_tables for update using (true);
drop policy if exists "public insert table_players" on table_players;
create policy "public insert table_players" on table_players for insert with check (true);
drop policy if exists "public update table_players" on table_players;
create policy "public update table_players" on table_players for update using (true);
drop policy if exists "public delete table_players" on table_players;
create policy "public delete table_players" on table_players for delete using (true);

-- ============================================================
-- RPC-функции (единственный способ менять баланс/скины/очки)
-- ============================================================

-- Начислить/списать монеты с журналом. amount может быть отрицательным.
create or replace function fn_add_coins(p_yandex_id text, p_amount bigint, p_reason text, p_meta jsonb default '{}')
returns bigint
language plpgsql security definer as $$
declare v_new_balance bigint;
begin
  insert into profiles (yandex_id) values (p_yandex_id) on conflict do nothing;

  update profiles set coins = coins + p_amount, updated_at = now()
    where yandex_id = p_yandex_id
    returning coins into v_new_balance;

  insert into coin_transactions (yandex_id, amount, reason, meta)
    values (p_yandex_id, p_amount, p_reason, p_meta);

  return v_new_balance;
end; $$;

-- Купить скин: проверяет цену и баланс сама, атомарно.
create or replace function fn_buy_skin(p_yandex_id text, p_skin_id text)
returns boolean
language plpgsql security definer as $$
declare v_price integer; v_balance bigint;
begin
  select price_coins into v_price from skins where id = p_skin_id;
  if v_price is null then
    raise exception 'unknown skin %', p_skin_id;
  end if;

  select coins into v_balance from profiles where yandex_id = p_yandex_id;
  if v_balance is null or v_balance < v_price then
    return false;
  end if;

  if exists (select 1 from user_skins where yandex_id = p_yandex_id and skin_id = p_skin_id) then
    return true; -- уже куплен
  end if;

  update profiles set coins = coins - v_price, updated_at = now() where yandex_id = p_yandex_id;
  insert into coin_transactions (yandex_id, amount, reason, meta)
    values (p_yandex_id, -v_price, 'skin_purchase', jsonb_build_object('skin_id', p_skin_id));
  insert into user_skins (yandex_id, skin_id) values (p_yandex_id, p_skin_id);

  return true;
end; $$;

-- Добавить очки текущего активного сезона нужного типа ('daily'/'weekly'/'monthly').
create or replace function fn_add_season_score(p_yandex_id text, p_period_type text, p_score bigint)
returns void
language plpgsql security definer as $$
declare v_season_id uuid;
begin
  select id into v_season_id from seasons
    where period_type = p_period_type and is_active = true and now() between starts_at and ends_at
    limit 1;
  if v_season_id is null then return; end if;

  insert into season_scores (season_id, yandex_id, score) values (v_season_id, p_yandex_id, p_score)
    on conflict (season_id, yandex_id) do update set score = season_scores.score + excluded.score;
end; $$;

-- Рассчитать сессию на ставках по итогу сессии.
-- p_totals = {"yandex_id": суммарные_очки_за_сессию, ...} — ТОЛЬКО реальные
-- игроки (боты не платят вход и не участвуют в выплатах).
-- Награда по месту: ×2 / ×1.5 / ×0.5 / 0 от внесённой суммы одного игрока
-- (stake_per_pulka × pulkas_total) — фиксированная схема независимо от
-- того, сколько мест заняли боты: тот, кто сел и играл, получает свой
-- результат по этой шкале.
create or replace function fn_settle_stake_table(p_table_id uuid, p_totals jsonb)
returns void
language plpgsql security definer as $$
declare v_stake_per_pulka integer; v_pulkas int; v_entry bigint; r record; v_rank int := 0;
  v_multipliers numeric[] := array[2, 1.5, 0.5, 0];
begin
  select stake_per_pulka, pulkas_total into v_stake_per_pulka, v_pulkas
    from game_tables where id = p_table_id;
  v_entry := v_stake_per_pulka * v_pulkas; -- сколько внёс один игрок при входе

  for r in
    select key as yandex_id, (value::bigint) as total_score
    from jsonb_each_text(p_totals)
    order by (value::bigint) desc
  loop
    v_rank := v_rank + 1;
    perform fn_add_coins(r.yandex_id, floor(v_entry * v_multipliers[v_rank])::bigint, 'stake_settle',
      jsonb_build_object('table_id', p_table_id, 'rank', v_rank, 'entry', v_entry));
  end loop;

  update game_tables set status = 'finished', finished_at = now() where id = p_table_id;
end; $$;

-- Списать вход при старте сессии на ставках (вызывать один раз на игрока при посадке за стол).
create or replace function fn_charge_stake_entry(p_yandex_id text, p_table_id uuid)
returns boolean
language plpgsql security definer as $$
declare v_stake_per_pulka integer; v_pulkas int; v_entry bigint; v_balance bigint;
begin
  select stake_per_pulka, pulkas_total into v_stake_per_pulka, v_pulkas from game_tables where id = p_table_id;
  v_entry := v_stake_per_pulka * v_pulkas;

  select coins into v_balance from profiles where yandex_id = p_yandex_id;
  if v_balance is null or v_balance < v_entry then
    return false; -- не хватает монет на этот уровень ставок
  end if;

  perform fn_add_coins(p_yandex_id, -v_entry, 'stake_entry', jsonb_build_object('table_id', p_table_id));
  return true;
end; $$;

-- Отменить стол и вернуть ставку ВСЕМ реальным (не боты) игрокам, кто уже
-- сидел за ним. Вызывается автором стола, если за 60 сек поиска не
-- набралось минимум 2 живых игрока (или явной отмены). Всё в одной
-- транзакции — безопасно даже если кто-то из игроков одновременно
-- пытается что-то ещё сделать за этим столом.
create or replace function fn_cancel_table_and_refund(p_table_id uuid)
returns void
language plpgsql security definer as $$
declare v_stake integer; v_pulkas int; v_entry bigint; r record;
begin
  select stake_per_pulka, pulkas_total into v_stake, v_pulkas from game_tables where id = p_table_id;
  if v_stake is null then return; end if;
  v_entry := v_stake * v_pulkas;

  for r in select yandex_id from table_players where table_id = p_table_id and is_bot = false loop
    perform fn_add_coins(r.yandex_id, v_entry, 'stake_refund', jsonb_build_object('table_id', p_table_id));
  end loop;

  delete from table_players where table_id = p_table_id;
  update game_tables set status = 'cancelled' where id = p_table_id;
end; $$;

-- Включаем realtime-репликацию на столах/местах, чтобы счётчик "N/4" в
-- лобби обновлялся мгновенно у всех подключённых клиентов (без этого
-- postgres_changes-подписка молча ничего не присылает, и счётчик виснет).
-- Безопасно перезапускать: пропускаем таблицы, которые уже добавлены.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'game_tables'
  ) then
    alter publication supabase_realtime add table game_tables;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'table_players'
  ) then
    alter publication supabase_realtime add table table_players;
  end if;
end $$;
insert into skins (id, name, description, price_coins, is_default) values
  ('classic', 'Классическая колода', 'Стандартный вид карт', 0, true)
on conflict (id) do nothing;

-- Служебные профили-боты — ими занимают пустые места за столом, если за
-- минуту не набралось 4 живых игрока. У ботов баланс не используется и не
-- участвует в расчёте банка (fn_settle_stake_table получает только реальных
-- игроков в p_totals).
insert into profiles (yandex_id, display_name) values
  ('bot_1', 'Бот 1'), ('bot_2', 'Бот 2'), ('bot_3', 'Бот 3')
on conflict (yandex_id) do nothing;

-- ============================================================
-- Правила дисконнекта/тайм-аута:
-- - На каждое решение (заказ козыря, заявка, ход картой) даётся 10 секунд
--   реального времени. Не успел — клиент, который ведёт стол (хост,
--   обычно тот, кто создал стол/сел первым), сам играет за игрока простым
--   легальным ходом, и это место помечается «на автопилоте» до тех пор,
--   пока игрок не нажмёт «Я тут» в интерфейсе.
-- - table_players.is_bot = true, если место изначально занял бот
--   (никто не подключился за минуту поиска) — такое место бот доигрывает
--   до конца сессии.
-- - table_players.last_seen_at обновляется клиентом при возврате в игру
--   (нажатии «Я тут»), чтобы было видно историю активности.
-- - Ставка (fn_charge_stake_entry) уже списана при входе, поэтому уйти от
--   проигрыша отключением нельзя — итог всё равно относится к игроку,
--   даже если весь остаток сессии за него доигрывал бот.
-- ============================================================
