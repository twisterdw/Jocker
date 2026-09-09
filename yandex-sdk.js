// Подключение Yandex Games SDK.
// В index.html перед этим файлом должен быть подключён:
// <script src="https://yandex.ru/games/sdk/v2"></script>

let ysdk = null;
let player = null;

export async function initYandexSDK() {
  // За пределами Яндекс Игр (например, тест на GitHub Pages) объекта
  // YaGames нет вообще — не падаем, а работаем в гостевом режиме.
  if (typeof YaGames === 'undefined') {
    console.warn('YaGames SDK не найден — гостевой режим (тест вне Яндекс Игр).');
    ysdk = null;
    player = null;
    return { ysdk, player };
  }
  ysdk = await YaGames.init();
  try {
    player = await ysdk.getPlayer();
  } catch (e) {
    // Игрок не авторизован в Яндексе — можно играть анонимно,
    // но монеты/скины в этом случае не сохранятся между сессиями.
    player = null;
  }
  return { ysdk, player };
}

// Вызывать сразу как только на экране можно взаимодействовать
// (например, когда показан экран выбора формата игры).
export function markGameReady() {
  ysdk?.features?.LoadingAPI?.ready();
}

export function getYandexId() {
  if (player) return player.getUniqueID();
  // Гостевой тестовый режим (GitHub Pages и т.п.): выдаём и запоминаем
  // локальный ID, чтобы можно было проверить запись в Supabase.
  // На реальном Яндекс Игры этот код не выполнится, т.к. player там есть.
  if (typeof YaGames === 'undefined') {
    let guestId = localStorage.getItem('joker_guest_id');
    if (!guestId) {
      guestId = 'guest-' + Math.random().toString(36).slice(2, 10);
      localStorage.setItem('joker_guest_id', guestId);
    }
    return guestId;
  }
  return null;
}

export function getPlayerName() {
  return player ? player.getName() : 'Гость';
}

export function getPlayerPhoto(size = 'medium') {
  return player ? player.getPhoto(size) : null;
}

// Показ полноэкранной рекламы между пульками. Обязательно ставить
// игру/звук на паузу на onOpen и снимать на onClose — иначе не пройдёт модерацию.
export function showInterstitialAd({ onOpen, onClose } = {}) {
  ysdk?.adv.showFullscreenAdv({
    callbacks: {
      onOpen: () => onOpen?.(),
      onClose: () => onClose?.(),
      onError: () => onClose?.(),
    },
  });
}

// Лидерборд (например, "недельная лига"). Имя таблицы нужно
// заранее завести в кабинете разработчика Яндекс Игр.
export async function setLeaderboardScore(leaderboardName, score) {
  if (!ysdk) return;
  await ysdk.leaderboards.setScore(leaderboardName, score);
}

export async function getLeaderboardEntries(leaderboardName, limit = 10) {
  if (!ysdk) return [];
  const res = await ysdk.leaderboards.getEntries(leaderboardName, { quantityTopSurrounding: limit });
  return res.entries;
}

// Покупка монет за реальные деньги через платформу (если решишь добавить донат).
// id должен быть заведён в кабинете разработчика как внутриигровой товар.
export async function purchaseCoinsPack(productId) {
  const payments = await ysdk.getPayments({ signed: true });
  const purchase = await payments.purchase({ id: productId });
  return purchase; // purchase.signature отправлять на свой сервер/Supabase Edge Function для зачисления
}
