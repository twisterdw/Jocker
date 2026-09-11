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
// Создание/чтение идёт через rpc (security definer) — прямой insert
// в profiles блокируется RLS-политикой (только чтение разрешено напрямую).
export async function ensureProfile(yandexId, displayName) {
  const { data, error } = await supabase.rpc('fn_ensure_profile', {
    p_yandex_id: yandexId, p_display_name: displayName,
  });
  if (error) throw error;
  return data;
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
  const { error } = await supabase.rpc('fn_equip_skin', { p_yandex_id: yandexId, p_skin_id: skinId });
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

// ---------- Матчмейкинг (лобби столов) ----------

// Найти стол в статусе "waiting" на нужную ставку/формат и подсесть на
// свободное место, либо создать новый стол и сесть первым (место 0).
// Гонки (два клиента целятся в одно и то же место) отбиваются самой БД —
// (table_id, seat) уникален, вставка второго просто упадёт, и код пробует
// следующее место/стол.
// Реализовано атомарно на сервере (fn_join_or_create_table, см.
// supabase_schema.sql): вся проверка "есть свободное место" и вставка
// происходят под блокировкой строки стола в одной транзакции — это
// гарантирует, что за уже полный (4/4) или не-waiting стол никто не
// подсядет, даже при одновременном подключении нескольких игроков.
export async function findOrCreateTable(yandexId, stakePerPulka, pulkasTotal) {
  const { data, error } = await supabase.rpc('fn_join_or_create_table', {
    p_yandex_id: yandexId, p_stake: stakePerPulka, p_pulkas: pulkasTotal,
  });
  if (error) throw error;
  const row = Array.isArray(data) ? data[0] : data;
  return { tableId: row.table_id, mySeat: row.seat, isCreator: row.is_creator, searchDeadline: row.search_deadline };
}

// Единая точка принятия решения "начать/отменить стол" — вызывать
// периодически ЛЮБЫМ клиентом за столом (не только автором), пока идёт
// поиск. Идемпотентно и безопасно при параллельных вызовах от нескольких
// клиентов одновременно (см. fn_finalize_table_search): реальную работу
// выполнит только тот вызов, который первым захватит блокировку строки
// стола, остальные получат уже установившийся статус без побочных эффектов.
// Раньше эту роль выполнял только клиент автора стола, и если его вкладка
// сворачивалась (частый случай в мобильном браузере), стол зависал
// навсегда — теперь от конкретного клиента ничего не зависит.
// Возвращает: 'waiting' | 'playing' | 'cancelled'.
export async function finalizeTableSearch(tableId) {
  const { data, error } = await supabase.rpc('fn_finalize_table_search', { p_table_id: tableId });
  if (error) throw error;
  return data;
}

// Игрок сам выходит из поиска — убирает только его место и возвращает
// только ему его ставку; на остальных живых игроков за этим же столом это
// не влияет (см. fn_leave_search_and_refund).
export async function leaveSearchAndRefund(yandexId, tableId) {
  const { error } = await supabase.rpc('fn_leave_search_and_refund', { p_yandex_id: yandexId, p_table_id: tableId });
  if (error) throw error;
}

// Статус стола + единый дедлайн поиска (search_deadline) — один и тот же
// момент времени для ВСЕХ клиентов за этим столом (записан автором при
// создании), чтобы отсчёт "осталось Nс" совпадал у всех, а не считался
// каждым клиентом по-своему.
export async function getTableInfo(tableId) {
  const { data, error } = await supabase.from('game_tables').select('status, search_deadline').eq('id', tableId).single();
  if (error) return null;
  return data;
}

// Отменить стол и вернуть монеты ВСЕМ реальным (не боты) игрокам, кто уже
// сидел за ним — вызывает только автор стола, если за 60 сек не набралось
// минимум 2 живых игрока. Считает и списывает/возвращает атомарно на
// сервере (fn_cancel_table_and_refund), поэтому безопасно при гонках.
export async function cancelTableAndRefund(tableId) {
  const { error } = await supabase.rpc('fn_cancel_table_and_refund', { p_table_id: tableId });
  if (error) throw error;
}

export async function listTablePlayers(tableId) {
  const { data, error } = await supabase.from('table_players').select('seat, yandex_id, is_bot').eq('table_id', tableId).order('seat');
  if (error) throw error;
  return data;
}

// Занять ботами все места, не занятые живыми игроками за минуту поиска,
// и перевести стол в статус "playing". bot_1/bot_2/bot_3 — общие
// служебные профили (см. supabase_schema.sql), их можно использовать
// одновременно на разных столах — это просто ярлык, а не аккаунт.
export async function fillRemainingSeatsWithBots(tableId, existingPlayers) {
  const taken = new Set(existingPlayers.map(p => p.seat));
  const botIds = ['bot_1', 'bot_2', 'bot_3'];
  let botI = 0;
  const inserts = [];
  for (let seat = 0; seat < 4; seat++) {
    if (taken.has(seat)) continue;
    inserts.push({ table_id: tableId, seat, yandex_id: botIds[botI % botIds.length], is_bot: true });
    botI++;
  }
  if (inserts.length > 0) {
    const { error } = await supabase.from('table_players').insert(inserts);
    if (error) throw error;
  }
  await supabase.from('game_tables').update({ status: 'playing' }).eq('id', tableId);
  return listTablePlayers(tableId);
}

// Покинуть стол до начала игры (отмена поиска) — просто убирает место.
export async function leaveTable(tableId, seat) {
  await supabase.from('table_players').delete().eq('table_id', tableId).eq('seat', seat);
}

// ---------- Realtime-канал самой игры (broadcast, без сохранения на сервере) ----------
// Общий канал стола: публичное состояние (чей ход, что на столе, счёт,
// количество карт у каждого — БЕЗ содержимого чужих рук) + ходы от
// не-хоста к хосту. Хост — тот из живых игроков, кто сидит на меньшем
// по номеру месте.
export function openGameChannel(tableId, { onState, onMove } = {}) {
  const ch = supabase.channel(`game:${tableId}`, { config: { broadcast: { self: false } } });
  if (onState) ch.on('broadcast', { event: 'state' }, (msg) => onState(msg.payload));
  if (onMove) ch.on('broadcast', { event: 'move' }, (msg) => onMove(msg.payload));
  ch.subscribe();
  return ch;
}

export function broadcastGameState(channel, statePayload) {
  channel.send({ type: 'broadcast', event: 'state', payload: statePayload });
}

export function sendGameMove(channel, movePayload) {
  channel.send({ type: 'broadcast', event: 'move', payload: movePayload });
}

// Приватный канал руки — подписывается только сам игрок этого места, чтобы
// содержимое его карт не уходило остальным подписчикам общего канала.
export function openHandChannel(tableId, seat, onHand) {
  const ch = supabase.channel(`game:${tableId}:hand:${seat}`, { config: { broadcast: { self: false } } });
  ch.on('broadcast', { event: 'hand' }, (msg) => onHand(msg.payload));
  ch.subscribe();
  return ch;
}

export function sendHandTo(tableId, seat, cardKeys) {
  const ch = supabase.channel(`game:${tableId}:hand:${seat}`, { config: { broadcast: { self: false } } });
  ch.subscribe((status) => {
    if (status === 'SUBSCRIBED') {
      ch.send({ type: 'broadcast', event: 'hand', payload: { cards: cardKeys } });
      setTimeout(() => ch.unsubscribe(), 300);
    }
  });
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
