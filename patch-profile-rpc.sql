-- ============================================================
-- Патч: profiles создаётся/меняется только через RPC.
-- Почему: таблица profiles защищена RLS, а политики есть только
-- на чтение (select). Прямой insert/update от клиента (anon-ключ)
-- упирается в ошибку 42501 "new row violates row-level security
-- policy". Правильное решение — как и остальные rpc в схеме
-- (fn_add_coins, fn_buy_skin) — сделать это через security definer
-- функции, которые работают в обход RLS, но сами проверяют условия.
--
-- Вставить целиком в Supabase → SQL Editor → Run.
-- ============================================================

-- Найти профиль по yandex_id, а если его ещё нет — создать
-- с приветственным бонусом 1000 монет.
create or replace function fn_ensure_profile(p_yandex_id text, p_display_name text default 'Игрок')
returns profiles
language plpgsql security definer as $$
declare v_profile profiles;
begin
  select * into v_profile from profiles where yandex_id = p_yandex_id;
  if found then
    return v_profile;
  end if;

  insert into profiles (yandex_id, display_name, equipped_skin_id, coins)
    values (p_yandex_id, coalesce(p_display_name, 'Игрок'), 'classic', 1000)
    returning * into v_profile;

  insert into coin_transactions (yandex_id, amount, reason)
    values (p_yandex_id, 1000, 'welcome_bonus');

  return v_profile;
end; $$;

-- Сменить экипированный скин — проверяет, что скин куплен
-- (или что это бесплатный 'classic'), прежде чем экипировать.
create or replace function fn_equip_skin(p_yandex_id text, p_skin_id text)
returns void
language plpgsql security definer as $$
begin
  if p_skin_id <> 'classic'
     and not exists (select 1 from user_skins where yandex_id = p_yandex_id and skin_id = p_skin_id) then
    raise exception 'skin % not owned by %', p_skin_id, p_yandex_id;
  end if;

  update profiles set equipped_skin_id = p_skin_id, updated_at = now()
    where yandex_id = p_yandex_id;
end; $$;
