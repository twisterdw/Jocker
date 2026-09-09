// Клиент Supabase.
// Вариант A (без сборщика, для теста на GitHub Pages) — импорт прямо из CDN, как сейчас ниже.
// Вариант B (если позже добавите Vite/Webpack) — можно вернуть
// "import { createClient } from '@supabase/supabase-js'" и установить пакет через npm install.
// URL и ключ взять в Supabase → Project Settings → API (anon public key,
// НЕ service_role — тот ключ должен оставаться только на сервере).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://oglmskzoeoxvedduinoh.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_Tp20aGRSoVziJZ1rGIo5og_Gqt7QDQS';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------- Профиль ----------
export async function ensureProfile(yandexId, displayName) {
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('yandex_id', yandexId)
    .maybeSingle();
  if (error) throw error;
  if (data) return data;

  const { data: created, error: insErr } = await supabase
    .from('profiles')
    .insert({ yandex_id: yandexId, display_name: displayName, equipped_skin_id: 'classic', coins: 1000 })
    .select()
    .single();
  if (insErr) throw insErr;
  return created;
}

export async function getProfile(yandexId) {
  const { data, error } = await supabase.from('profiles').select('*').eq('yandex_id', yandexId).single();
  if (error) throw error;
  return data;
}

// ---------- Монеты (всегда через rpc — прямой update запрещён политиками RLS) ----------
export async function addCoins(yandexId, amount, reason, meta = {}) {
  const { data, error } = await supabase.rpc('fn_add_coins', {
    p_yandex_id: yandexId, p_amount: amount, p_reason: reason, p_meta: meta,
  });
  if (error) throw error;
  return data; // новый баланс
}

// ---------- Магазин скинов ----------
export async function listSkins() {
  const { data, error } = await supabase.from('skins').select('*').order('price_coins');
  if (error) throw error;
  return data;
}

export async function listOwnedSkins(yandexId) {
  const { data, error } = await supabase.from('user_skins').select('skin_id').eq('yandex_id', yandexId);
  if (error) throw error;
  return data.map(r => r.skin_id);
}

export async function buySkin(yandexId, skinId) {
  const { data, error } = await supabase.rpc('fn_buy_skin', { p_yandex_id: yandexId, p_skin_id: skinId });
  if (error) throw error;
  return data; // true/false — хватило ли монет
}

export async function equipSkin(yandexId, skinId) {
  const { error } = await supabase.from('profiles').update({ equipped_skin_id: skinId }).eq('yandex_id', yandexId);
  // Если понадобится строже — вынести и это в rpc-функцию с проверкой владения скином.
  if (error) throw error;
}

// ---------- Лиги / сезоны ----------
export async function addSeasonScore(yandexId, periodType, score) {
  const { error } = await supabase.rpc('fn_add_season_score', {
    p_yandex_id: yandexId, p_period_type: periodType, p_score: score,
  });
  if (error) throw error;
}

export async function getSeasonLeaderboard(seasonId, limit = 20) {
  const { data, error } = await supabase
    .from('season_scores')
    .select('yandex_id, score, profiles(display_name)')
    .eq('season_id', seasonId)
    .order('score', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data;
}

// ---------- Столы на ставках ----------
export const STAKE_TIERS = [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200];

// Реалтайм-подписка на изменения конкретного стола — использовать для
// синхронизации хода/козыря/взятки между 4 клиентами.
export function subscribeToTable(tableId, onChange) {
  return supabase
    .channel(`table:${tableId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'game_history', filter: `table_id=eq.${tableId}` }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'table_players', filter: `table_id=eq.${tableId}` }, onChange)
    .subscribe();
}

// Вызвать один раз на игрока при посадке за стол на ставках — списывает
// stake_per_pulka × 4 сразу. Возвращает false, если монет не хватает.
export async function chargeStakeEntry(yandexId, tableId) {
  const { data, error } = await supabase.rpc('fn_charge_stake_entry', {
    p_yandex_id: yandexId, p_table_id: tableId,
  });
  if (error) throw error;
  return data;
}

// Обновлять при каждом ходе/пинге игрока — по этому серверная часть
// понимает, когда подключать бота вместо игрока (тайм-аут хода — 20 сек).
export async function touchLastSeen(tableId, seat) {
  const { error } = await supabase.from('table_players')
    .update({ last_seen_at: new Date().toISOString() })
    .eq('table_id', tableId).eq('seat', seat);
  if (error) throw error;
}

// Вызвать по итогу всех 4 пулек сессии. p_totals — суммарные очки каждого
// игрока за 4 пульки вместе; распределяет банк по формуле 2х/1.5х/0.5х/0.
export async function settleStakeSession(tableId, totalsByYandexId) {
  const { error } = await supabase.rpc('fn_settle_stake_table', {
    p_table_id: tableId, p_totals: totalsByYandexId,
  });
  if (error) throw error;
}
