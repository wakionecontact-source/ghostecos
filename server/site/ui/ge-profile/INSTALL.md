# Профиль GhostEcos — инструкция по вставке

Модуль уже выложен на прод и отдаётся с сайта:

- `https://ghostecos.duckdns.org/social/assets/ge-profile.js`
- `https://ghostecos.duckdns.org/social/assets/ge-profile.css`

CSS подключается сам: скрипт находит `ge-profile.css` рядом с собой. Отдельный `<link>` не нужен.

Условие работы — страница на том же origin, что и API соцсети (`/api/soc`): иначе не будет сессии и запросы вернут 401.

## 1. Одна строка — фиксированный профиль

```html
<script src="/social/assets/ge-profile.js" data-ge-profile="orlova"></script>
```

Что произойдёт: скрипт поставит контейнер сразу после себя, подгрузит стили и загрузит `/api/soc/prof/orlova`.

Свой профиль и ссылка для «Поделиться»:

```html
<script src="/social/assets/ge-profile.js"
        data-ge-profile="orlova"
        data-share-url="https://ghostecos.duckdns.org/v2/social/@"></script>
```

`data-share-url` — префикс, ник добавится сам.

## 2. Две строки — своё место в разметке

```html
<div data-ge-profile="orlova"></div>
<script src="/social/assets/ge-profile.js" defer></script>
```

Контейнер монтируется при загрузке страницы и позже, если его добавили в DOM: MutationObserver находит новые `[data-ge-profile]`.

## 3. Без сети — готовые данные

```html
<div data-ge-profile-json='{"username":"orlova","name":"Ольга","isMe":false}'></div>
```

`data-ge-json` — то же самое. Сеть не используется, кнопки работают в локальном режиме и шлют события.

Кастомный элемент:

```html
<ge-profile user="orlova"></ge-profile>
<script src="/social/assets/ge-profile.js" defer></script>
```

## 4. Динамический профиль (соцсеть, SPA)

Когда ник известен только в момент открытия профиля:

```js
const host = document.getElementById('geProfilePublic');
const profile = GeProfile.connect(host, { username: 'orlova' });
await profile.load();          // GET /api/soc/prof/orlova
```

`connect()` сразу запускает загрузку. Если данные уже есть:

```js
profile.update(raw);           // ответ API целиком
profile.renderView(view);      // готовая модель вида
```

Методы: `load()`, `refresh()`, `update(raw)`, `renderView(view)`, `openEditor()`, `openStatus()`, `openMusic()`, `destroy()`; свойства `data`, `raw`, `tracks`, `username`.

Если контейнер создаётся позже:

```js
GeProfile.scan(node);
```

## 5. Атрибуты

| Где | Атрибут | Смысл |
| --- | --- | --- |
| `<script>` | `data-ge-profile` или `data-user` | ник: контейнер создаётся сам |
| `<script>` | `data-api` | база API, по умолчанию `/api/soc` |
| `<script>` | `data-share-url` | префикс ссылки для «Поделиться» |
| `<div>` | `data-ge-profile` | ник для контейнера |
| `<div>` | `data-ge-profile-json` / `data-ge-json` | готовые данные, без сети |
| `<div>` | `data-ge-profile-api` | своя база API для этого блока |
| `<ge-profile>` | `user` / `username`, `api` | ник и база API |

## 6. Куда вставлять

- В `social.html` — перед `</body>`, отдельным `<script>`. Живые `app.js` и разметку профиля это не меняет.
- В любую страницу GhostEcos на том же домене (например, в мессенджер) — те же две строки.
- В сторонний домен — только с `data-api` на публичный API соцсети и без расчёта на вход: сессии там не будет.

Для замены существующих экранов профиля в соцсети нужна правка `app.js`: при открытии профиля вызвать `profile.update(raw)` или `connect({ username })`. Без такой правки модуль работает рядом, а не вместо.

## 7. Свой и чужой профиль

Модуль ничего не угадывает: сервер в `/prof/{ник}` отдаёт `is_me`.

- `is_me: true` — «Редактировать» и «Поделиться», кликабельны аватар и статус.
- `is_me: false` — «Подписаться»/«Отписаться», «Написать», поделиться.

Для гостя сервер вернёт `is_me: false`, и профиль откроется в публичном виде.

## 8. Оформление

Палитра по умолчанию совпадает с `/v2/social`. Переопределение — переменными на корне:

```css
.ge-profile {
  --ge-primary: #82cfa7;
  --ge-surface: #15161a;
  --ge-font: 'IBM Plex Sans', sans-serif;
}
```

Модификаторы: `ge-profile--own`, `ge-profile--public`, `ge-profile--compact`, `ge-profile--surface`, `ge-profile--no-banner`, `ge-profile--status-inline`.

## 9. События

```js
host.addEventListener('ge-profile:ready', (e) => console.log(e.detail.profile));
host.addEventListener('ge-profile:follow', (e) => console.log(e.detail.following));
host.addEventListener('ge-profile:action', (e) => console.log(e.detail.action));
host.addEventListener('ge-profile:status', (e) => console.log(e.detail.text));
host.addEventListener('ge-profile:error', (e) => console.log(e.detail.error));
```

Полный список: `ready`, `error`, `action`, `tab`, `post`, `follow`, `profile`, `status`, `music`.

## 10. Проверка

```powershell
curl.exe -sS -o NUL -w "%{http_code}`n" https://ghostecos.duckdns.org/social/assets/ge-profile.js
```

На странице — в консоли:

```js
document.querySelectorAll('.ge-profile').length
```

## 11. Если не работает

| Симптом | Причина |
| --- | --- |
| 401 | нет сессии или страница на другом origin |
| 404 «User not found» | ник не существует или передан с `@` (модуль срезает `@`, но лучше без него) |
| Ничего не появилось | нет `data-ge-profile` и нет `connect()` |
| Два профиля | подключены два скрипта или контейнер и `data-ge-profile` одновременно |
| Вид «поехал» | не загрузился `ge-profile.css` (файл переименован или лежит в другом каталоге) |
| Старый код после выкладки | кэш: добавьте `?v=2` к `src` |

## 12. Выкладка обновлений

```powershell
scp ghostecos server/site/ui/ge-profile/ge-profile.js server/site/ui/ge-profile/ge-profile.css ":/var/www/ghostsocial/assets/"
```

После выкладки сверить хеши и отдачу:

```powershell
(Get-FileHash server/site/ui/ge-profile/ge-profile.js -Algorithm SHA256).Hash
ssh ghostecos "sha256sum /var/www/ghostsocial/assets/ge-profile.js"
```
