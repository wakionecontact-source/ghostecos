/* ════════════════════════════════════════════════════════════════════
   social-aug.js — комменты-аугментация GhostSocial
   DESKTOP: оборачивает каждый .post-card в .post-row + .post-comments-aside
            и тянет первые 10 комментов из /com/get/{id}
   MOBILE:  перехватывает клик на [data-action="comment"] и открывает
            pca-sheet с клоном поста сверху + комментами снизу
   Использует существующие глобалы app.js: api, commentHTML, esc, me
   ════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  if (window.__SOCIAL_AUG_LOADED__) return;
  window.__SOCIAL_AUG_LOADED__ = true;

  var MOBILE_BREAKPOINT = 1023;
  var isMobile = function () { return window.innerWidth <= MOBILE_BREAKPOINT; };

  // shortcut'ы к глобалам app.js (могут отсутствовать на ранней стадии)
  function api(path, method, body) {
    if (typeof window.api === 'function') return window.api(path, method, body);
    return Promise.reject(new Error('api() not ready'));
  }
  // EMOJI и emojiSvg берём из app.js (там полноценные SVG-иконки как у поста)
  var EMOJI_ORDER = ['heart', 'fire', 'laugh', 'sad', 'clap', 'eyes'];
  function emojiSvg(key) {
    if (typeof window.emojiSvg === 'function') return window.emojiSvg(key);
    var fb = { heart:'❤', fire:'🔥', laugh:'😂', sad:'😢', clap:'👏', eyes:'👀' };
    return '<span>' + (fb[key] || '?') + '</span>';
  }

  // SVG иконка стрелки-reply (вместо ↳ unicode — кастом)
  var REPLY_ARROW_SVG =
    '<svg class="ca-arrow-icon" width="12" height="12" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<polyline points="9 17 4 12 9 7"/><path d="M20 18v-2a4 4 0 0 0-4-4H4"/></svg>';

  function commentHTML(c) {
    var rx = c.reactions || { counts: {}, your_emoji: null, total: 0 };
    var yours = rx.your_emoji || null;
    var total = rx.total || 0;
    var hasMine = yours ? ' has-mine' : '';

    var repliesCnt = c.replies_count || 0;
    var repliesBtn = (c.parent_id || repliesCnt === 0) ? '' :
      '<button type="button" class="ca-replies-btn" data-cid="' + c.id + '" data-count="' + repliesCnt + '">' +
        REPLY_ARROW_SVG + ' <span class="crb-label">Показать ответы (' + repliesCnt + ')</span>' +
      '</button>';

    // Quote-плашка для ответа на ответ
    var quoteHtml = '';
    if (c.parent_id && c.reply_to_id && c.reply_to_id !== c.parent_id && c.reply_to_username) {
      var q = c.reply_to_text || '';
      if (q.length > 60) q = q.slice(0, 60) + '…';
      quoteHtml =
        '<button type="button" class="ca-quote" data-jump-to="' + c.reply_to_id + '">' +
          REPLY_ARROW_SVG +
          '<span class="ca-quote-to">@' + escTxt(c.reply_to_username) + '</span>' +
          '<span class="ca-quote-text">' + escTxt(q) + '</span>' +
        '</button>';
    }

    return '<div class="comment-item ca-item' + (c.parent_id ? ' ca-reply' : '') + '" data-cid="' + c.id + '">' +
      '<div class="ca-row">' +
        '<div class="ca-main">' +
          '<div class="ca-head">' +
            '<span class="ca-user">@' + escTxt(c.username) + '</span> ' +
            '<span class="ca-name">' + escTxt(c.display_name || c.username) + '</span>' +
          '</div>' +
          quoteHtml +
          '<div class="ca-text">' + escTxt(c.text) + '</div>' +
          '<div class="ca-bar">' +
            '<button type="button" class="ca-reply-link" data-cid="' + c.id + '" data-to="' + escTxt(c.username) + '">Ответить</button>' +
            repliesBtn +
          '</div>' +
          '<div class="ca-replies" data-replies-of="' + c.id + '" hidden></div>' +
        '</div>' +
        // Heart-кнопка как у поста: react-trigger обёртка для long-press палитры
        '<div class="ca-react react-trigger" data-cid="' + c.id + '">' +
          '<button type="button" class="ca-heart' + hasMine + '" data-cid="' + c.id + '" data-action="ca-heart-toggle"' +
            (yours ? ' data-emoji="' + yours + '"' : '') + '>' +
            (yours ? emojiSvg(yours) : '<i class="fa-regular fa-heart"></i>') +
          '</button>' +
          '<span class="ca-react-n"' + (total ? '' : ' hidden') + '>' + (total || 0) + '</span>' +
        '</div>' +
      '</div>' +
    '</div>';
  }

  function plural(n, forms) {
    var n10 = n % 10, n100 = n % 100;
    if (n10 === 1 && n100 !== 11) return forms[0];
    if (n10 >= 2 && n10 <= 4 && (n100 < 10 || n100 >= 20)) return forms[1];
    return forms[2];
  }

  // ─── Глобальный reply-режим для каждой формы (aside/sheet) ───
  // Состояние хранится на самой форме через data-attrs:
  //   form.dataset.replyCid       — id родителя (если включен)
  //   form.dataset.replyUsername  — для placeholder и плашки
  //   form.dataset.replyText      — текст-цитата
  function enterReplyMode(form, cid, username, text) {
    form.dataset.replyCid = String(cid);
    form.dataset.replyUsername = username;
    form.dataset.replyText = text;
    var input = form.querySelector('.pca-input');
    if (input) {
      input.placeholder = 'Ответить @' + username + '...';
      input.focus();
    }
    var banner = form.previousElementSibling;
    if (!banner || !banner.classList.contains('pca-reply-banner')) {
      banner = document.createElement('div');
      banner.className = 'pca-reply-banner';
      form.parentNode.insertBefore(banner, form);
    }
    banner.innerHTML =
      '<div class="prb-bar">' +
        '<div class="prb-text">' +
          '<div class="prb-to">Ответ @' + escTxt(username) + '</div>' +
          '<div class="prb-quote">' + escTxt(text.length > 80 ? text.slice(0, 80) + '…' : text) + '</div>' +
        '</div>' +
        '<button type="button" class="prb-x" aria-label="Отменить">✕</button>' +
      '</div>';
    banner.querySelector('.prb-x').addEventListener('click', function () { exitReplyMode(form); });
  }

  function exitReplyMode(form) {
    delete form.dataset.replyCid;
    delete form.dataset.replyUsername;
    delete form.dataset.replyText;
    var input = form.querySelector('.pca-input');
    if (input) input.placeholder = 'Написать комментарий...';
    var banner = form.previousElementSibling;
    if (banner && banner.classList.contains('pca-reply-banner')) banner.remove();
  }

  // Находим composer-форму ближе всего к коменту (для aside или для sheet)
  function findComposerFor(commentEl) {
    if (!commentEl) return null;
    var sheet = commentEl.closest('.pca-sheet');
    if (sheet) return sheet.querySelector('[data-pca-form]');
    var aside = commentEl.closest('.post-comments-aside');
    if (aside) return aside.querySelector('[data-pca-form]');
    return null;
  }
  function escTxt(s) {
    if (typeof window.esc === 'function') return window.esc(s);
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // ─── DESKTOP: оборачиваем .post-card → .post-row[post + aside] ───
  function wrapPostCard(card) {
    if (!card || !card.parentElement) return;
    if (card.parentElement.classList.contains('post-row')) return;
    var id = card.getAttribute('data-id');
    if (!id) return;

    var row = document.createElement('div');
    row.className = 'post-row';
    row.dataset.postId = id;

    var aside = document.createElement('aside');
    aside.className = 'post-comments-aside';
    aside.dataset.postId = id;
    aside.dataset.sort = 'top';
    aside.innerHTML =
      '<div class="pca-head">' +
        '<i class="fa-solid fa-comment"></i>' +
        '<span>Комментарии</span>' +
        '<span class="pca-count" data-pca-count>0</span>' +
      '</div>' +
      '<div class="pca-sort">' +
        '<button type="button" class="pca-sort-btn active" data-sort="top">' +
          '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M12 17.27 18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"/>' +
          '</svg> Топ' +
        '</button>' +
        '<button type="button" class="pca-sort-btn" data-sort="new">' +
          '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' +
            '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>' +
          '</svg> Новые' +
        '</button>' +
      '</div>' +
      '<div class="pca-list"><div class="pca-loading">Загрузка...</div></div>' +
      '<form class="pca-form" data-pca-form data-post-id="' + id + '">' +
        '<input class="pca-input" type="text" placeholder="Написать комментарий..." maxlength="500" autocomplete="off">' +
        '<button class="pca-send" type="submit" title="Отправить">' +
          '<i class="fa-solid fa-paper-plane"></i>' +
        '</button>' +
      '</form>';

    var parent = card.parentNode;
    parent.insertBefore(row, card);
    row.appendChild(card);
    row.appendChild(aside);

    loadComments(id, aside.querySelector('.pca-list'), aside.querySelector('[data-pca-count]'));

    // Aside не должен быть выше поста. align-self:start на post-card даёт
    // короткому посту брать свою высоту, но aside тянулся независимо
    // вверх → визуально лоскутно. ResizeObserver зеркалит .post-card высоту
    // на aside.maxHeight, внутри aside .pca-list скроллится.
    if (typeof ResizeObserver !== 'undefined') {
      try {
        var ro = new ResizeObserver(function (entries) {
          for (var i = 0; i < entries.length; i++) {
            var h = entries[i].contentRect.height;
            if (h > 0) aside.style.maxHeight = Math.max(h, 200) + 'px';
          }
        });
        ro.observe(card);
      } catch(_) {}
    }
  }

  // ─── Подгрузка комментов с lazy-load ───
  // Поведение: при первой загрузке тянем пачку. Если коменты есть и место
  // в scroll-контейнере ещё не заполнено и has_more=true → подгружаем ещё.
  // На scroll до конца — подгружаем следующую пачку. Когда has_more=false →
  // показываем "Комментариев больше нет".
  var LAZY_BATCH = 5; // если бек поддерживает limit — будет по 5

  function getCtx(listEl) {
    if (!listEl.__pcaCtx) {
      listEl.__pcaCtx = { offset: 0, loading: false, done: false, postId: null };
    }
    return listEl.__pcaCtx;
  }

  function renderEnd(listEl) {
    var existing = listEl.querySelector('.pca-end');
    if (existing) return;
    var end = document.createElement('div');
    end.className = 'pca-end';
    end.textContent = 'Комментариев больше нет';
    listEl.appendChild(end);
  }
  function clearEnd(listEl) {
    var existing = listEl.querySelector('.pca-end');
    if (existing) existing.remove();
  }

  function fetchPage(postId, offset, limit, sort) {
    var s = sort || 'top';
    var url = '/com/get/' + postId + '?offset=' + offset + '&limit=' + limit + '&sort=' + s;
    return api(url);
  }

  // Найти текущий sort для listEl (aside или sheet)
  function getSortFor(listEl) {
    var aside = listEl.closest('.post-comments-aside');
    if (aside) return aside.dataset.sort || 'top';
    var sheet = listEl.closest('.pca-sheet');
    if (sheet) return sheet.dataset.sort || 'top';
    return 'top';
  }

  // Тянем одну пачку и аппендим в listEl. Возвращает Promise<boolean has_more>.
  function loadOneBatch(postId, listEl, countEl) {
    var ctx = getCtx(listEl);
    if (ctx.loading || ctx.done) return Promise.resolve(false);
    ctx.loading = true;
    var sort = getSortFor(listEl);
    return fetchPage(postId, ctx.offset, LAZY_BATCH, sort).then(function (r) {
      var comments = (r && r.comments) || [];
      var hasMore = !!(r && r.has_more);
      ctx.loading = false;
      ctx.offset += comments.length;
      if (!hasMore) ctx.done = true;
      // первая пустая загрузка → пустое состояние
      if (ctx.offset === 0 && !comments.length) {
        listEl.innerHTML = '<div class="pca-empty">Пусто. Будь первым.</div>';
        return false;
      }
      // на первом непустом ответе — выкидываем placeholder'ы
      var placeholder = listEl.querySelector('.pca-loading, .pca-empty');
      if (placeholder) placeholder.remove();
      if (comments.length) {
        var html = comments.map(commentHTML).join('');
        listEl.insertAdjacentHTML('beforeend', html);
      }
      if (countEl) countEl.textContent = ctx.offset;
      if (ctx.done) renderEnd(listEl);
      return hasMore;
    }).catch(function () {
      ctx.loading = false;
      if (ctx.offset === 0) listEl.innerHTML = '<div class="pca-empty">Не удалось загрузить</div>';
      return false;
    });
  }

  // Циклически догружает пока scrollHeight <= clientHeight + buffer
  // (то есть пока всё помещается на экран без скролла) и есть has_more.
  function fillUntilScroll(postId, listEl, countEl) {
    return loadOneBatch(postId, listEl, countEl).then(function (hasMore) {
      if (!hasMore) return;
      if (listEl.scrollHeight > listEl.clientHeight + 40) return; // уже есть что скроллить
      return fillUntilScroll(postId, listEl, countEl);
    });
  }

  // Главная точка входа для aside / sheet
  function loadComments(postId, listEl, countEl) {
    if (!listEl) return;
    // сброс контекста на новый postId
    listEl.__pcaCtx = { offset: 0, loading: false, done: false, postId: postId };
    clearEnd(listEl);
    listEl.innerHTML = '<div class="pca-loading">Загрузка...</div>';
    // отслеживаем scroll для лениво-докачки
    if (!listEl.__pcaScrollBound) {
      listEl.__pcaScrollBound = true;
      listEl.addEventListener('scroll', function () {
        var c = getCtx(listEl);
        if (c.done || c.loading) return;
        var nearBottom = (listEl.scrollHeight - listEl.scrollTop - listEl.clientHeight) < 80;
        if (nearBottom) loadOneBatch(c.postId, listEl, countEl);
      });
    }
    fillUntilScroll(postId, listEl, countEl);
  }

  // ─── Отправка коммента: ОДНА composer-форма (aside или sheet).
  //     Reply-mode: если на форме есть dataset.replyCid — шлём parent_comment_id. ───
  document.addEventListener('submit', function (e) {
    var form = e.target.closest && e.target.closest('[data-pca-form]');
    if (!form) return;
    e.preventDefault();
    var input = form.querySelector('.pca-input');
    var text = (input.value || '').trim();
    if (!text) return;
    var postId = form.dataset.postId;
    if (!postId) return;
    var btn = form.querySelector('.pca-send');
    if (btn) btn.disabled = true;

    var parentId = form.dataset.replyCid ? parseInt(form.dataset.replyCid, 10) : null;
    var body = { text: text };
    if (parentId) body.parent_comment_id = parentId;

    api('/com/' + postId, 'POST', body).then(function (resp) {
      input.value = '';
      var myUsername = (window.me && window.me.username) || 'you';
      var myDisplay = (window.me && window.me.display_name) || myUsername;
      var newCid = resp && resp.comment_id;
      var savedParentId = resp && resp.parent_id;

      if (parentId) {
        // ─── Reply: вставляем в раскрытый replies-блок parent'а (если он есть)
        var holder = document.querySelector('[data-replies-of="' + savedParentId + '"]');
        if (holder) {
          // Получаем reply_to_username/text для quote-плашки (если ответ был на reply)
          var replyToUser = form.dataset.replyUsername;
          var replyToText = form.dataset.replyText;
          var newReply = {
            id: newCid,
            text: text,
            created_at: new Date().toISOString(),
            parent_id: savedParentId,
            reply_to_id: parentId,
            username: myUsername,
            display_name: myDisplay,
            reactions: { counts: {}, your_emoji: null, total: 0 },
            replies_count: 0,
            reply_to_username: (parentId !== savedParentId) ? replyToUser : null,
            reply_to_text: (parentId !== savedParentId) ? replyToText : null
          };
          // если placeholder/loading — заменим
          var ph = holder.querySelector('.pca-loading, .pca-empty');
          if (ph) ph.remove();
          holder.hidden = false;
          holder.insertAdjacentHTML('beforeend', commentHTML(newReply));
          holder.dataset.loaded = '1';
        }
        // Обновить лейбл «Показать ответы (N)»
        var rb = document.querySelector('.ca-replies-btn[data-cid="' + savedParentId + '"]');
        if (rb) {
          var n = (parseInt(rb.dataset.count, 10) || 0) + 1;
          rb.dataset.count = n;
          rb.textContent = '↳ Показать ответы (' + n + ')';
        } else {
          // у parent ещё не было кнопки (был 0 ответов) — добавим её
          var parentBar = document.querySelector('.ca-item[data-cid="' + savedParentId + '"] .ca-bar');
          if (parentBar) {
            parentBar.insertAdjacentHTML('beforeend',
              '<button type="button" class="ca-replies-btn" data-cid="' + savedParentId +
              '" data-count="1">↳ Показать ответы (1)</button>');
          }
        }
        exitReplyMode(form);
      } else {
        // ─── Top-level: prepend в начало списка БЕЗ перерисовки
        var newComment = {
          id: newCid,
          text: text,
          created_at: new Date().toISOString(),
          parent_id: null,
          reply_to_id: null,
          username: myUsername,
          display_name: myDisplay,
          reactions: { counts: {}, your_emoji: null, total: 0 },
          replies_count: 0
        };
        var lists = [
          document.querySelector('.post-comments-aside[data-post-id="' + postId + '"] .pca-list')
        ];
        var sheet = document.getElementById('pcaSheet');
        if (sheet && sheet.classList.contains('open') && sheet.dataset.postId === postId) {
          lists.push(sheet.querySelector('.pca-sheet-list'));
        }
        lists.forEach(function (lst) {
          if (!lst) return;
          var empty = lst.querySelector('.pca-empty');
          if (empty) empty.remove();
          lst.insertAdjacentHTML('afterbegin', commentHTML(newComment));
        });
        // счётчик total в шапке taблетки
        var countEl = document.querySelector('.post-comments-aside[data-post-id="' + postId + '"] [data-pca-count]');
        if (countEl) countEl.textContent = (parseInt(countEl.textContent, 10) || 0) + 1;
      }
      var cc = document.querySelector('[data-post="' + postId + '"][data-action="comment"] .cc');
      if (cc) cc.textContent = (parseInt(cc.textContent, 10) || 0) + 1;
    }).catch(function () {
      alert('Не удалось отправить');
    }).then(function () {
      if (btn) btn.disabled = false;
    });
  });

  // ─── Sort chips (Топ/Новые) ───
  document.addEventListener('click', function (e) {
    var sb = e.target.closest && e.target.closest('.pca-sort-btn');
    if (!sb) return;
    e.preventDefault();
    if (sb.classList.contains('active')) return;
    var sort = sb.dataset.sort;
    var container = sb.closest('.post-comments-aside, .pca-sheet');
    if (!container) return;
    container.dataset.sort = sort;
    container.querySelectorAll('.pca-sort-btn').forEach(function (b) {
      b.classList.toggle('active', b === sb);
    });
    // Reset + reload
    var listEl, countEl, postId;
    if (container.classList.contains('post-comments-aside')) {
      listEl = container.querySelector('.pca-list');
      countEl = container.querySelector('[data-pca-count]');
      postId = container.dataset.postId;
    } else {
      listEl = container.querySelector('.pca-sheet-list');
      countEl = null;
      postId = container.dataset.postId;
    }
    if (postId && listEl) loadComments(postId, listEl, countEl);
  });

  // ─── Клики на кнопки коммента ───
  document.addEventListener('click', function (e) {
    // Quote-плашка: jump to parent комменту (если в DOM) и подсветить
    var quote = e.target.closest && e.target.closest('.ca-quote');
    if (quote) {
      e.preventDefault();
      e.stopPropagation();
      var target = parseInt(quote.dataset.jumpTo, 10);
      var el = document.querySelector('.ca-item[data-cid="' + target + '"]');
      if (el) {
        el.scrollIntoView({ behavior: 'smooth', block: 'center' });
        el.classList.add('ca-flash');
        setTimeout(function () { el.classList.remove('ca-flash'); }, 1400);
      }
      return;
    }
    var tgt = e.target.closest && e.target.closest('.ca-reply-link, .ca-replies-btn, [data-action="ca-heart-toggle"]');
    if (!tgt) return;
    e.preventDefault();
    e.stopPropagation();
    var cid = tgt.dataset.cid;
    if (!cid) return;

    if (tgt.classList.contains('ca-reply-link')) {
      var item = tgt.closest('.ca-item');
      var textEl = item.querySelector('.ca-text');
      var form = findComposerFor(item);
      if (form) enterReplyMode(form, cid, tgt.dataset.to, textEl ? textEl.textContent : '');
      return;
    }

    if (tgt.classList.contains('ca-replies-btn')) {
      var holder = document.querySelector('[data-replies-of="' + cid + '"]');
      if (!holder) return;
      var labelEl = tgt.querySelector('.crb-label');
      var n = parseInt(tgt.dataset.count, 10) || 0;
      if (!holder.hidden && holder.dataset.loaded === '1') {
        // collapse
        holder.classList.add('ca-collapsing');
        setTimeout(function () {
          holder.hidden = true;
          holder.classList.remove('ca-collapsing');
        }, 240);
        tgt.classList.remove('open');
        if (labelEl) labelEl.textContent = 'Показать ответы (' + n + ')';
        return;
      }
      // expand
      holder.hidden = false;
      tgt.classList.add('open');
      if (labelEl) labelEl.textContent = 'Скрыть ответы (' + n + ')';
      if (holder.dataset.loaded !== '1') loadReplies(cid, holder, true);
      return;
    }

    // heart toggle
    if (tgt.matches('[data-action="ca-heart-toggle"]')) {
      // если был long-press — клик игнорируется (флаг устанавливается ниже)
      if (tgt.__longPressed) { tgt.__longPressed = false; return; }
      // Клик по сердцу ВСЕГДА шлёт 'heart' — сервер сам toggle'нёт
      // (если уже heart — снимет; если другой эмодзи — заменит на heart; нет — поставит).
      sendCommentReaction(cid, 'heart', tgt);
      return;
    }
  }, true);

  // ─── Long-press на heart-кнопке → открыть палитру с 6 эмодзи ───
  var _caPaletteOpenFor = null;
  function closeCaPalette() { if (_caPaletteOpenFor) { _caPaletteOpenFor.remove(); _caPaletteOpenFor = null; } }
  document.addEventListener('click', function (e) {
    if (_caPaletteOpenFor && !e.target.closest('.ca-palette') && !e.target.closest('[data-action="ca-heart-toggle"]')) closeCaPalette();
  });
  document.addEventListener('pointerdown', function (e) {
    var btn = e.target.closest && e.target.closest('[data-action="ca-heart-toggle"]');
    if (!btn) return;
    var pressTimer = setTimeout(function () {
      btn.__longPressed = true;
      openCaPalette(btn);
    }, 420);
    var cancel = function () { clearTimeout(pressTimer); };
    btn.addEventListener('pointerup', cancel, { once: true });
    btn.addEventListener('pointerleave', cancel, { once: true });
    btn.addEventListener('pointercancel', cancel, { once: true });
  }, true);

  function openCaPalette(triggerBtn) {
    closeCaPalette();
    var cid = triggerBtn.dataset.cid;
    var cur = triggerBtn.dataset.emoji || null;
    var bar = document.createElement('div');
    bar.className = 'ca-palette';
    bar.innerHTML = EMOJI_ORDER.map(function (k) {
      return '<button class="ca-pal-btn' + (k === cur ? ' active' : '') +
             '" data-emoji="' + k + '">' + emojiSvg(k) + '</button>';
    }).join('');
    // FIXED-позиционирование на body чтобы не было обрезки рамкой aside/overflow
    document.body.appendChild(bar);
    var br = triggerBtn.getBoundingClientRect();
    // Сначала ставим bar чтобы измерить его размеры
    bar.style.position = 'fixed';
    bar.style.visibility = 'hidden';
    bar.style.left = '0px';
    bar.style.top = '0px';
    bar.classList.add('open');
    var pw = bar.offsetWidth;
    var ph = bar.offsetHeight;
    // желаемая позиция: над heart-кнопкой, по центру
    var top = br.top - ph - 8;
    var left = br.left + br.width / 2 - pw / 2;
    var dropDown = false;
    if (top < 8) {
      // не помещается сверху → открываем под heart
      top = br.bottom + 8;
      dropDown = true;
    }
    // clamp по горизонтали в viewport
    if (left < 8) left = 8;
    if (left + pw > window.innerWidth - 8) left = window.innerWidth - pw - 8;
    bar.style.left = left + 'px';
    bar.style.top = top + 'px';
    bar.style.visibility = '';
    if (dropDown) bar.classList.add('drop-down');

    bar.querySelectorAll('.ca-pal-btn').forEach(function (b) {
      b.addEventListener('click', function (ev) {
        ev.stopPropagation();
        var em = b.dataset.emoji;
        sendCommentReaction(cid, em === cur ? null : em, triggerBtn);
        closeCaPalette();
      });
    });
    _caPaletteOpenFor = bar;
  }

  function sendCommentReaction(cid, emoji, heartBtn) {
    // если emoji=null — нужно "снять" (бек тогглит сам когда тот же эмодзи)
    // но для null-снятия отправим current emoji чтобы сервер toggle'нул.
    var send = emoji;
    if (send === null) send = heartBtn.dataset.emoji || 'heart';
    api('/com/' + cid + '/react', 'POST', { emoji: send }).then(function (r) {
      // r: { your_emoji, counts, total }
      heartBtn.classList.toggle('has-mine', !!r.your_emoji);
      if (r.your_emoji) {
        heartBtn.dataset.emoji = r.your_emoji;
        heartBtn.innerHTML = emojiSvg(r.your_emoji);
      } else {
        delete heartBtn.dataset.emoji;
        heartBtn.innerHTML = '<i class="fa-regular fa-heart"></i>';
      }
      var nEl = heartBtn.parentNode.querySelector('.ca-react-n');
      var total = r.total || 0;
      if (total > 0) {
        if (nEl) nEl.textContent = total;
        else heartBtn.parentNode.insertAdjacentHTML('beforeend', '<span class="ca-react-n">' + total + '</span>');
      } else if (nEl) nEl.remove();
    }).catch(function () {});
  }

  function loadReplies(parentId, holder, reset) {
    if (reset) {
      holder.innerHTML = '<div class="pca-loading">…</div>';
      holder.dataset.loaded = '0';
    }
    api('/com/replies/' + parentId + '?offset=0&limit=20').then(function (r) {
      holder.innerHTML = (r.replies && r.replies.length)
        ? r.replies.map(commentHTML).join('')
        : '';
      holder.dataset.loaded = '1';
    }).catch(function () {
      holder.innerHTML = '<div class="pca-empty">Ошибка</div>';
    });
  }

  // ─── MOBILE bottom-sheet ───
  function ensureSheet() {
    var sheet = document.getElementById('pcaSheet');
    if (sheet) return sheet;
    sheet = document.createElement('div');
    sheet.id = 'pcaSheet';
    sheet.className = 'pca-sheet';
    sheet.dataset.sort = 'top';
    sheet.innerHTML =
      '<div class="pca-sheet-bar">' +
        '<span class="pca-sheet-title">Комментарии</span>' +
        '<button type="button" class="pca-sheet-close" aria-label="Закрыть">×</button>' +
      '</div>' +
      '<div class="pca-sheet-post"></div>' +
      '<div class="pca-sort pca-sort-sheet">' +
        '<button type="button" class="pca-sort-btn active" data-sort="top">' +
          '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M12 17.27 18.18 21l-1.64-7.03L22 9.24l-7.19-.61L12 2 9.19 8.63 2 9.24l5.46 4.73L5.82 21z"/>' +
          '</svg> Топ' +
        '</button>' +
        '<button type="button" class="pca-sort-btn" data-sort="new">' +
          '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">' +
            '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>' +
          '</svg> Новые' +
        '</button>' +
      '</div>' +
      '<div class="pca-sheet-list"><div class="pca-loading">Загрузка...</div></div>' +
      '<form class="pca-sheet-form" data-pca-form data-post-id="">' +
        '<input class="pca-input" type="text" placeholder="Написать..." maxlength="500" autocomplete="off">' +
        '<button class="pca-send" type="submit"><i class="fa-solid fa-paper-plane"></i></button>' +
      '</form>';
    document.body.appendChild(sheet);
    sheet.querySelector('.pca-sheet-close').addEventListener('click', closeSheet);
    // Esc закрывает
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && sheet.classList.contains('open')) closeSheet();
    });
    return sheet;
  }

  function openSheet(postId) {
    var sheet = ensureSheet();
    sheet.dataset.postId = postId;
    var form = sheet.querySelector('[data-pca-form]');
    if (form) form.dataset.postId = postId;
    // Клонируем сам пост
    var original = document.querySelector('.post-card[data-id="' + postId + '"]');
    var postArea = sheet.querySelector('.pca-sheet-post');
    if (postArea) {
      postArea.innerHTML = '';
      if (original) {
        var clone = original.cloneNode(true);
        clone.style.marginBottom = '0';
        postArea.appendChild(clone);
      }
    }
    // Грузим комменты
    loadComments(postId, sheet.querySelector('.pca-sheet-list'), null);
    requestAnimationFrame(function () { sheet.classList.add('open'); });
    document.body.style.overflow = 'hidden';
  }

  function closeSheet() {
    var sheet = document.getElementById('pcaSheet');
    if (sheet) sheet.classList.remove('open');
    document.body.style.overflow = '';
  }

  // Перехват клика на кнопку коммента — только на mobile
  document.addEventListener('click', function (e) {
    if (!isMobile()) return;
    var btn = e.target.closest && e.target.closest('[data-action="comment"]');
    if (!btn) return;
    var id = btn.dataset.post || btn.getAttribute('data-post');
    if (!id) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    openSheet(id);
  }, true); // capture: перехватываем ДО bubble-обработчиков app.js

  // ─── Media mirror: размытый «зеркальный» фон вокруг картинки ───
  // Берём src первой картинки в .post-media и ставим её как CSS-переменную
  // --bg-image на самом контейнере. CSS делает ::before с blur поверх неё.
  function decorateMedia(root) {
    (root || document).querySelectorAll('.post-media').forEach(function (m) {
      if (m.dataset.mirrored) return;
      // ищем первую видимую картинку или video (poster)
      var img = m.querySelector('img');
      var src = null;
      if (img) src = img.currentSrc || img.src;
      if (!src) {
        var vid = m.querySelector('video');
        if (vid) src = vid.poster || vid.getAttribute('poster');
      }
      if (!src) {
        // если img ещё не загружен — ждём load и повторим
        if (img && !img.complete) {
          img.addEventListener('load', function () { decorateMedia(m.parentNode); }, { once: true });
        }
        return;
      }
      m.style.setProperty('--bg-image', 'url("' + src.replace(/"/g, '\\"') + '")');
      m.dataset.mirrored = '1';
    });
  }

  // ─── MutationObserver: подхватываем новые посты ───
  var mo = new MutationObserver(function (muts) {
    if (isMobile()) {
      // на мобиле всё равно проставляем mirror — он работает и там
      muts.forEach(function (m) {
        m.addedNodes.forEach(function (n) {
          if (n.nodeType === 1) decorateMedia(n);
        });
      });
      return;
    }
    muts.forEach(function (m) {
      m.addedNodes.forEach(function (n) {
        if (n.nodeType !== 1) return;
        if (n.matches && n.matches('.post-card')) wrapPostCard(n);
        if (n.querySelectorAll) {
          n.querySelectorAll('.post-card').forEach(wrapPostCard);
        }
        decorateMedia(n);
      });
    });
  });

  function start() {
    if (!isMobile()) {
      document.querySelectorAll('.post-card').forEach(wrapPostCard);
    }
    decorateMedia(document);
    mo.observe(document.body, { childList: true, subtree: true });

    // При ресайзе с desktop → mobile или обратно — перерисуем при необходимости
    var wasMobile = isMobile();
    window.addEventListener('resize', function () {
      var nowMobile = isMobile();
      if (nowMobile === wasMobile) return;
      wasMobile = nowMobile;
      if (!nowMobile) {
        // desktop активирован: оборачиваем всё ещё не обёрнутое
        document.querySelectorAll('.post-card').forEach(wrapPostCard);
      } else {
        // mobile активирован: aside и так скрыт через CSS
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }

  // ─── Profile scroll fix: при открытии профиля сохраняем scrollY ленты,
  // при возврате — восстанавливаем. Без этого браузер сбрасывает scroll
  // когда .screen.active меняется (display:none сносит scroll-position). ───
  var _savedFeedScroll = 0;
  function wrapFn(name, before, after) {
    var orig = window[name];
    if (typeof orig !== 'function' || orig.__wrapped) return;
    var wrapped = function () {
      if (typeof before === 'function') { try { before.apply(this, arguments); } catch (_) {} }
      var r = orig.apply(this, arguments);
      if (typeof after === 'function') { try { after.apply(this, arguments); } catch (_) {} }
      return r;
    };
    wrapped.__wrapped = 1;
    window[name] = wrapped;
  }
  function saveScroll() {
    var feedActive = document.getElementById('screenFeed');
    if (feedActive && feedActive.classList.contains('active')) {
      _savedFeedScroll = window.scrollY || document.documentElement.scrollTop || 0;
    }
  }
  function restoreScroll() {
    var feedActive = document.getElementById('screenFeed');
    if (feedActive && feedActive.classList.contains('active') && _savedFeedScroll > 0) {
      requestAnimationFrame(function () {
        window.scrollTo(0, _savedFeedScroll);
      });
    }
  }
  // Подождём пока app.js определит функции
  function tryWrap() {
    if (typeof window.openFullProfile === 'function' && !window.openFullProfile.__wrapped) {
      wrapFn('openFullProfile', saveScroll, null);
    }
    if (typeof window.restoreScreen === 'function' && !window.restoreScreen.__wrapped) {
      wrapFn('restoreScreen', null, restoreScroll);
    }
    if (typeof window.openTag === 'function' && !window.openTag.__wrapped) {
      wrapFn('openTag', saveScroll, null);
    }
    if (typeof window.openMini === 'function' && !window.openMini.__wrapped) {
      wrapFn('openMini', saveScroll, null);
    }
  }
  setTimeout(tryWrap, 200);
  setTimeout(tryWrap, 800);
  setTimeout(tryWrap, 2000);
})();
