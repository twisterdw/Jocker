-- ============================================================
-- Joker (Джокер) — патч матчмейкинга лобби
-- Вставить целиком в Supabase → SQL Editor → Run (после основной supabase_schema.sql)
--
-- ЧТО ЧИНИТ:
-- 1) "Стол стоит и не запускается" / "время дошло до 0 и зависло" —
--    раньше решение "начать игру ботами / отменить стол" принимал
--    ТОЛЬКО клиент автора стола. Если вкладка автора свёрнута (типично
--    для мобильного браузера — экран заблокирован/переключились на
--    другое приложение), setInterval у него не тикает, и стол зависает
--    навсегда. Теперь решение принимает атомарная функция на сервере
--    (fn_finalize_table_search), и её дёргают ВСЕ клиенты за столом —
--    сработает у того, кто первый успеет, у остальных это просто
--    безопасный no-op.
-- 2) "Показывает 3 игроков, когда включились только 2" — "призрак":
--    игрок закрыл вкладку/потерял связь во время поиска, не успев
--    выйти по кнопке, и его место осталось занятым навсегда. Теперь
--    finalize сам подчищает места без свежего heartbeat (last_seen_at)
--    старше 20 секунд — клиент обязан пинговать fn touchLastSeen
--    каждые несколько секунд, пока идёт поиск.
-- 3) "4/4 — играть сразу, без ожидания таймера" и "не подсаживать
--    новых игроков за уже полный стол" — теперь это атомарно
--    гарантируется на сервере одной транзакцией с блокировкой строки
--    стола (for update), а не двумя независимыми select/insert из
--    браузера, между которыми раньше была гонка.
-- ============================================================

-- Атомарный "найти стол или создать свой" — весь поиск свободного места
-- и вставка происходят под блокировкой строки стола (for update), поэтому
-- два игрока никогда не проверяют "есть ли свободное место" по устаревшим
-- данным одновременно, и никто не подсаживается на уже полный (4/4) или
-- не-waiting стол.
create or replace function fn_join_or_create_table(p_yandex_id text, p_stake integer, p_pulkas int)
returns table(table_id uuid, seat int, is_creator boolean, search_deadline timestamptz)
language plpgsql security definer as $$
declare
  v_table record;
  v_taken int[];
  v_seat int;
  s int;
begin
  for v_table in
    select gt.id, gt.search_deadline
    from game_tables gt
    where gt.status = 'waiting' and gt.stake_per_pulka = p_stake and gt.pulkas_total = p_pulkas
    order by gt.created_at asc
    for update
  loop
    select array_agg(tp.seat) into v_taken from table_players tp where tp.table_id = v_table.id;
    v_seat := null;
    for s in 0..3 loop
      if v_taken is null or not (s = any(v_taken)) then
        v_seat := s;
        exit;
      end if;
    end loop;

    if v_seat is not null then
      insert into table_players (table_id, seat, yandex_id, last_seen_at)
        values (v_table.id, v_seat, p_yandex_id, now());
      return query select v_table.id, v_seat, false, v_table.search_deadline;
      return;
    end if;
    -- этот стол уже полон (4/4) — пробуем следующий waiting-стол в списке
  end loop;

  -- Подходящего стола со свободным местом нет — создаём новый и садимся первым.
  insert into game_tables (status, stake_per_pulka, pulkas_total, mode, search_deadline)
    values ('waiting', p_stake, p_pulkas, 'nines_short', now() + interval '60 seconds')
    returning id, search_deadline into v_table;
  insert into table_players (table_id, seat, yandex_id, last_seen_at)
    values (v_table.id, 0, p_yandex_id, now());
  return query select v_table.id, 0, true, v_table.search_deadline;
end; $$;

-- Единая точка принятия решения по столу в поиске. Вызывается ПЕРИОДИЧЕСКИ
-- ЛЮБЫМ клиентом за столом (не только автором) — благодаря "for update" и
-- проверке status <> 'waiting' в начале, повторные/параллельные вызовы
-- безопасны и идемпотентны: реальную работу выполнит только тот вызов,
-- который первым захватит блокировку строки, для остальных функция сразу
-- вернёт уже установившийся статус.
-- Возвращает: 'waiting' | 'playing' | 'cancelled'.
create or replace function fn_finalize_table_search(p_table_id uuid)
returns text
language plpgsql security definer as $$
declare
  v_table record;
  v_real_count int;
  v_taken int[];
  v_bot_ids text[] := array['bot_1','bot_2','bot_3'];
  v_bot_i int := 0;
  s int;
begin
  select * into v_table from game_tables where id = p_table_id for update;
  if v_table is null then
    return 'cancelled';
  end if;
  if v_table.status <> 'waiting' then
    return v_table.status; -- уже решено другим клиентом раньше — просто сообщаем текущий статус
  end if;

  -- Подчищаем "призраков": реальных игроков без свежего heartbeat
  -- (клиент должен вызывать touchLastSeen раз в несколько секунд, пока
  -- идёт поиск) — считаем их отключившимися и освобождаем место.
  delete from table_players
    where table_id = p_table_id and is_bot = false and last_seen_at < now() - interval '20 seconds';

  select count(*) into v_real_count from table_players where table_id = p_table_id and is_bot = false;

  if v_real_count >= 4 then
    -- Все 4 места заняли живые игроки — начинаем сразу, не дожидаясь таймера.
    update game_tables set status = 'playing' where id = p_table_id;
    return 'playing';
  end if;

  if now() < v_table.search_deadline then
    return 'waiting'; -- время поиска ещё не вышло — ждём
  end if;

  -- Дедлайн истёк.
  if v_real_count >= 2 then
    select array_agg(tp.seat) into v_taken from table_players tp where tp.table_id = p_table_id;
    for s in 0..3 loop
      if v_taken is null or not (s = any(v_taken)) then
        insert into table_players (table_id, seat, yandex_id, is_bot, last_seen_at)
          values (p_table_id, s, v_bot_ids[(v_bot_i % 3) + 1], true, now());
        v_bot_i := v_bot_i + 1;
      end if;
    end loop;
    update game_tables set status = 'playing' where id = p_table_id;
    return 'playing';
  else
    perform fn_cancel_table_and_refund(p_table_id);
    return 'cancelled';
  end if;
end; $$;

-- Игрок сам вышел из поиска (кнопка "Отменить и вернуть монеты") — убирает
-- ТОЛЬКО его место и возвращает ЕМУ ЛИЧНО его ставку; на остальных живых
-- игроков за этим же столом это больше не влияет (раньше отмена от лица
-- автора сносила весь стол и деньги возвращались всем — это было не по
-- смыслу кнопки для не-автора и мешало столу, если автор просто передумал).
-- Если после ухода за столом не осталось ни одного живого игрока — стол
-- целиком отменяется (чтобы не оставался висеть пустым в списке waiting).
create or replace function fn_leave_search_and_refund(p_yandex_id text, p_table_id uuid)
returns void
language plpgsql security definer as $$
declare v_stake integer; v_pulkas int; v_status text; v_remaining int;
begin
  select stake_per_pulka, pulkas_total, status into v_stake, v_pulkas, v_status
    from game_tables where id = p_table_id for update;
  if v_status is null or v_status <> 'waiting' then
    return; -- игра уже началась/завершилась/отменена — тут выходить некуда
  end if;

  delete from table_players where table_id = p_table_id and yandex_id = p_yandex_id and is_bot = false;
  perform fn_add_coins(p_yandex_id, v_stake * v_pulkas, 'stake_refund',
    jsonb_build_object('table_id', p_table_id, 'reason', 'left_search'));

  select count(*) into v_remaining from table_players where table_id = p_table_id and is_bot = false;
  if v_remaining = 0 then
    delete from table_players where table_id = p_table_id;
    update game_tables set status = 'cancelled' where id = p_table_id;
  end if;
end; $$;
