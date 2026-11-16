# Профиль GhostEcos — модуль

Профиль пользователя как самостоятельный блок: один вид в GhostSocial, GhostChat и любом другом сервисе. Внешний вид снят с живого `/v2/social` один в один, но разметка, стили и логика больше не зависят от страницы, на которой живут.

```
ge-profile/
  ge-profile.js    — данные, рендер, действия (главный файл)
  ge-profile.css   — стили в скоупе .ge-profile, свои токены
  demo.html        — все варианты сразу, для проверки глазами
  README.md
```

Пошаговая инструкция «что и куда вставлять» — `INSTALL.md` рядом с модулем.

## Подключение одной строкой

```html
<script src="/social/assets/ge-profile.js" data-ge-profile="orlova"></script>
```

Скрипт сам подставляет `ge-profile.css`, создаёт контейнер сразу после себя и грузит профиль из соцсети. Ни `<link>`, ни инициализации писать не нужно.

Атрибуты скрипта:

| Атрибут | Смысл |
| --- | --- |
| `data-ge-profile` (или `data-user`) | ник пользователя — профиль загрузится сам |
| `data-api` | база API, по умолчанию `/api/soc` |
| `data-share-url` | префикс ссылки для «Поделиться», по умолчанию текущий адрес |

Другие способы поставить профиль:

```html
<div data-ge-profile="orlova"></div>          <!-- грузит /prof/orlova -->
<ge-profile user="orlova"></ge-profile>        <!-- то же кастомным элементом -->
<div data-ge-profile-json='{"name":"orlova","handle":"@orlova"}'></div>
```

Контейнеры вида `data-ge-profile` модуль находит сам, в том числе добавленные позже — MutationObserver следит за DOM.

## Слой данных

`GET /api/soc/prof/{username}` превращается в модель вида через `GeProfile.normalize(raw)`. Поддерживаются поля живого ответа: `display_name`, `username`, `user_id`, `about`/`bio`, `avatar_url`, `media_banner`/`banner` (строка или объект), `daily_status`, `is_verified`, `is_admin`/`is_moderator`/`shields`, `reputation_score`/`reputation_band`, `following_count`, `followers_count`, `likes_received`, `followers_added_today`, `created_at`, `profile_music`, `posts`.

```js
const profile = GeProfile.connect(document.getElementById('host'), {
  username: 'orlova',      // или готовые данные: data: raw
});
await profile.load();     // GET /prof/orlova, состояния и ошибки внутри
```

Методы экземпляра: `load()`/`refresh()`, `update(raw)` — ответ API, `renderView(view)` — готовая модель без сети, `openEditor()`, `openStatus()`, `openMusic()`, `destroy()`; свойства `data`, `raw`, `tracks`, `username`.

## Что модуль делает сам

| Действие | Запрос |
| --- | --- |
| Подписка/отписка | `POST` / `DELETE /api/soc/follow/{username}` |
| Редактор профиля | `PATCH /api/soc/me/profile` (`display_name`, `username`, `about`) |
| Аватар | `POST /api/soc/me/avatar` (multipart `file`), `DELETE` — убрать |
| Статус дня | `POST /api/soc/status/set` (`text`, до 140 симв.) |
| Музыка профиля | `PATCH /api/soc/me/profile` (`profile_music[]` или `music_clear`) |
| Поделиться | `navigator.share`, иначе копирование ссылки |

Кнопки собираются из данных: у своего профиля — «Редактировать» и «Поделиться», у чужого — «Подписаться»/«Отписаться», «Написать», поделиться. Аватар и статус у своего профиля кликабельны.

Авторизация: `Authorization: Bearer` из `localStorage.gs_token`, cookie `gs_token` или `gs_me.token`; запросы идут с `credentials: 'include'` и `X-Ghost-Web: 1`, как в живом клиенте.

## События

Все всплывают от корня и повторяют действия наружу — хост может перехватить или дополнить:

```js
host.addEventListener('ge-profile:action', (e) => console.log(e.detail.action));
host.addEventListener('ge-profile:tab', (e) => console.log(e.detail.tab));
host.addEventListener('ge-profile:post', (e) => console.log(e.detail.post));
host.addEventListener('ge-profile:follow', (e) => console.log(e.detail.following));
host.addEventListener('ge-profile:profile', (e) => console.log(e.detail.profile));
host.addEventListener('ge-profile:status', (e) => console.log(e.detail.text));
host.addEventListener('ge-profile:music', (e) => console.log(e.detail));
host.addEventListener('ge-profile:ready', (e) => console.log(e.detail.profile));
host.addEventListener('ge-profile:error', (e) => console.log(e.detail.error));
```

## Состояния

- загрузка — скелетон с теми же отступами, что у готовой карточки;
- ошибка — текст и кнопка «Повторить» (повторяет `load`);
- пусто — «Публикаций пока нет» / «Репостов пока нет»;
- вкладка репостов берёт `reposts` из ответа профиля, отдельного запроса модуль не делает; если данных нет — показывает пустое состояние и отдаёт `ge-profile:tab`.

## Токены и модификаторы

Всё оформление на переменных `--ge-`. Значения по умолчанию — палитра GhostSocial v2 (`#111113`, `#b39af4`, `#9b9ba5`), поэтому на соцсети вид не меняется. Другой сервис перекрашивает профиль одной строкой:

```css
.ge-profile {
  --ge-primary: #82cfa7;
  --ge-surface: #15161a;
  --ge-font: 'IBM Plex Sans', sans-serif;
}
```

Геометрия: `--ge-avatar-size`, `--ge-banner-height`, `--ge-notch`, `--ge-action-height`, `--ge-grid-radius`.
Модификаторы на корне: `ge-profile--own`, `ge-profile--public`, `ge-profile--compact`, `ge-profile--surface`, `ge-profile--no-banner`, `ge-profile--status-inline`.

## Разметка

Разметка живёт только в `ge-profile.js`: серверного шаблона нет, одна и та же вёрстка собирается и для соцсети, и для мессенджера. Если у хоста уже есть данные, передайте их без сети:

```js
GeProfile.mount(root, view)     // готовая модель, offline: true
GeProfile.connect(root, { username: 'orlova' }).load()   // реальный `/prof`
```

`GeProfile.mount` по умолчанию работает без сети (`offline: true`): действия меняют состояние на месте и шлют события. Так устроено демо; для реальной загрузки используйте `connect()` или подключение скриптом.

## Демо

`demo.html` открывается как есть (рядом должны лежать `ge-profile.js` и `ge-profile.css`): четыре варианта — свой, чужой, компактный, пустой. Клики, редактор, статус, вкладки и музыка работают без сервера.

## Интеграция в соцсеть

Сейчас в `v2/social.html` профиль — два блока (`#screenProfile` и `#screenFullProfile`), куда `assets/app.js` пишет через `getElementById`. Порядок перевода:

1. Оба экрана сводятся к контейнерам `#geProfileOwn` и `#geProfilePublic`.
2. `loadMyProfile`/`openFullProfile` вместо заполнения `#profName`, `#profBio` вызывают `update(raw)` или `connect({ username })`.
3. Кнопки (`openEditProfile`, `switchProfTab`, follow) переводятся на события модуля; либо остаются родные — модуль умеет всё сам.
4. Старые id можно оставить пустыми: модуль их не использует.

Сетка постов может остаться у хоста: передайте `posts: []` и рисуйте свои карточки после монтирования.

## Мессенджер

```js
import GeProfile from '/social/assets/ge-profile.js';
import '/social/assets/ge-profile.css';

const profile = GeProfile.connect(node, { username: 'orlova' });
```

В мобильном профиле чата — `compact: true`: аватар 82px вместо 110px, обложка ниже.

## Отдача файлов

Продакшн — каталог соцсети `/var/www/ghostsocial/assets/`, он уже отдаётся существующим блоком:

```nginx
location /social/assets/ {
    alias /var/www/ghostsocial/assets/;
}
```

Выкладка (аддитивно, чужие файлы не трогаем):

```powershell
scp ghostecos server/site/ui/ge-profile/ge-profile.js server/site/ui/ge-profile/ge-profile.css ":/var/www/ghostsocial/assets/"
```

Проверка после выкладки:

```powershell
curl.exe -sS -o NUL -w "%{http_code} %{content_type}`n" https://ghostecos.duckdns.org/social/assets/ge-profile.js
curl.exe -sS -o NUL -w "%{http_code} %{content_type}`n" https://ghostecos.duckdns.org/social/assets/ge-profile.css
```

Отдельный алиас нужен, только если модуль кладут в другое место:

```nginx
location /ui/ {
    alias /opt/ghostchat/site/ui/;
    expires 7d;
    add_header Cache-Control "public";
}
```

## Ограничения

- Изоляция — CSS-скоуп, без Shadow DOM: правила хоста по служебным классам модуля могут их переопределить; стили на теги и наследование перекрыты. Проверено враждебным CSS — метрики не менялись.
- Иконки встроены SVG, Font Awesome не нужен.
- Шрифт по умолчанию — Inter с системным фолбэком.
- Проигрывание музыки — по жесту пользователя: браузер блокирует автозапуск, модуль показывает уведомление.
- Смена пароля в редактор не входит: это отдельный сценарий хоста.
- `:has()` в одном правиле отступа меты требует современный браузер; в старых отступ больше, вид не ломается.
