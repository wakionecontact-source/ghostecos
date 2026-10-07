(() => {
  "use strict";

  const ASSET_ROOT = "/gemo/v2/assets/models/";
  const catalog = new Map();
  const providerLabels = {
    groq: "Groq",
    mistral: "Mistral",
    openrouter: "OpenRouter",
    sambanova: "SambaNova",
  };
  const filterLabels = {
    all: "Все",
    free: "Бесплатные",
    premium: "PRO",
    multimodal: "Мультимодальные",
    available: "Доступные",
  };
  let currentFilter = "all";
  let currentQuery = "";
  let catalogModels = [];
  let catalogCurrent = "";
  let controls;
  let resultCount;
  let modelList;
  let observer;
  let refreshQueued = false;

  function escapeHTML(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, (char) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    })[char]);
  }

  function plainText(value) {
    return String(value == null ? "" : value).trim();
  }

  function brandFor(model) {
    const creator = plainText(model && model.creator).toLocaleLowerCase("ru");
    if (creator.includes("openai")) return "openai";
    if (creator.includes("qwen") || creator.includes("alibaba")) return "alibabacloud";
    if (creator.includes("mistral")) return "mistralai";
    if (creator.includes("openrouter")) return "openrouter";
    if (creator.includes("inclusion")) return "inclusionai";
    if (creator.includes("cohere")) return "cohere";
    if (creator.includes("google") || creator.includes("deepmind")) return "google";
    if (creator.includes("liquid")) return "liquidai";
    if (creator.includes("minimax")) return "minimax";
    if (creator.includes("nvidia")) return "nvidia";
    if (creator.includes("poolside")) return "poolside";
    if (creator.includes("thinking machines")) return "thinkingmachines";
    if (creator.includes("deepseek")) return "deepseek";
    if (creator === "meta" || creator.includes("meta ai")) return "meta";
    if (creator.includes("stealth")) return "stealth";
    return "unknown";
  }

  function providerName(provider) {
    const key = plainText(provider).toLowerCase();
    return providerLabels[key] || (key ? key.charAt(0).toUpperCase() + key.slice(1) : "Провайдер");
  }

  function formatParams(model) {
    if (plainText(model.params_label)) return plainText(model.params_label);
    if (Number.isFinite(Number(model.params_b)) && Number(model.params_b) > 0) {
      return Number(model.params_b).toLocaleString("ru-RU") + "B параметров";
    }
    return "Размер не раскрыт";
  }

  function formatRating(rating) {
    if (!rating || !Number(rating.votes)) return "";
    const average = Number(rating.average);
    if (!Number.isFinite(average)) return "";
    return "★ " + average.toLocaleString("ru-RU", { maximumFractionDigits: 1 }) + " · " + Number(rating.votes) + " оценок";
  }

  function modelSearchText(model) {
    return [model.name, model.model, model.key, model.creator, providerName(model.provider)]
      .map(plainText).join(" ").toLocaleLowerCase("ru");
  }

  function matchesFilter(model) {
    if (currentFilter === "free") return !model.premium;
    if (currentFilter === "premium") return !!model.premium;
    if (currentFilter === "multimodal") return !!model.multimodal;
    if (currentFilter === "available") return model.available !== false;
    return true;
  }

  function iconHTML(model) {
    const creator = escapeHTML(plainText(model.creator) || providerName(model.provider));
    return '<span class="mp-avatar" aria-hidden="true"><img src="' + ASSET_ROOT + brandFor(model) + '.svg" alt="" loading="lazy"/><span class="mp-avatar-fallback" hidden>AI</span></span>';
  }

  function pillHTML(label, extraClass) {
    return '<span class="mp-pill ' + (extraClass || "") + '">' + escapeHTML(label) + '</span>';
  }

  function resultCardHTML(model) {
    const name = plainText(model.name || model.key || "Модель");
    const available = model.available !== false;
    const isSelected = model.key === catalogCurrent || !!model.is_current;
    const badge = [
      model.premium ? '<span class="badge pro">PRO</span>' : pillHTML("Бесплатная", "mp-free"),
      model.multimodal ? pillHTML("Мультимодальная", "mp-media") : "",
      !available ? pillHTML(plainText(model.status_short) || "Недоступна", "mp-status") : "",
    ].join("");
    const description = !available
      ? (plainText(model.status_detail) || plainText(model.status_short) || "Сейчас недоступна")
      : (model.multimodal ? "Принимает изображения и другие файлы" : "Текстовая модель");
    const meta = [formatParams(model), plainText(model.creator), providerName(model.provider)].filter(Boolean).join(" · ");
    const rating = formatRating(model.rating);
    const selected = isSelected ? " on" : "";
    const disabled = available ? "" : " mp-unavailable";
    const id = escapeHTML(model.key);
    const provider = escapeHTML(model.provider);
    const aria = escapeHTML(name + ", " + providerName(model.provider) + (available ? "" : ", недоступна"));
    return '<button type="button" class="mcard mp-enhanced mp-global' + selected + disabled + '" data-id="' + id + '" data-provider="' + provider + '" data-available="' + (available ? "true" : "false") + '" aria-label="' + aria + '" aria-disabled="' + (!available) + '">' +
      iconHTML(model) +
      '<span class="mp-content"><span class="nm"><span class="mp-title">' + escapeHTML(name) + '</span>' + badge + '</span>' +
      '<span class="ds">' + escapeHTML(description) + '</span>' +
      '<span class="mp-card-footer"><span class="model-meta">' + escapeHTML(meta) + '</span>' + (rating ? '<span class="mp-rating">' + escapeHTML(rating) + '</span>' : "") + '</span></span>' +
      (isSelected ? '<span class="mp-selected" aria-hidden="true">Выбрана</span>' : "") +
      '</button>';
  }

  function installAvatarFallbacks(container) {
    container.querySelectorAll(".mp-avatar img").forEach((image) => {
      image.addEventListener("error", () => {
        image.hidden = true;
        const fallback = image.nextElementSibling;
        if (fallback) fallback.hidden = false;
      }, { once: true });
      if (image.complete && image.naturalWidth === 0) {
        image.hidden = true;
        if (image.nextElementSibling) image.nextElementSibling.hidden = false;
      }
    });
  }

  function updateCatalog(data) {
    if (!data || !data.providers || typeof data.providers !== "object") return;
    catalog.clear();
    catalogModels = [];
    Object.keys(data.providers).forEach((provider) => {
      (Array.isArray(data.providers[provider]) ? data.providers[provider] : []).forEach((model) => {
        if (!model || !model.key) return;
        const normalized = Object.assign({}, model, {
          provider,
          name: plainText(model.name || String(model.key).split(":").pop()),
          available: model.available !== false,
        });
        catalog.set(normalized.key, normalized);
        catalogModels.push(normalized);
      });
    });
    catalogCurrent = plainText(data.current || data.default);
    updateProviderCounts();
    refreshList();
  }

  function isModelsRequest(input) {
    const raw = typeof input === "string" ? input : (input && input.url) || "";
    try { return /(?:^|\/)models\/?$/i.test(new URL(raw, location.href).pathname); }
    catch (_) { return /(?:^|\/)models(?:[/?]|$)/i.test(String(raw)); }
  }

  if (typeof window.fetch === "function") {
    const originalFetch = window.fetch.bind(window);
    window.fetch = function (input, init) {
      return originalFetch(input, init).then(async (response) => {
        if (isModelsRequest(input)) {
          try { updateCatalog(await response.clone().json()); } catch (_) {}
        }
        return response;
      });
    };
  }

  function makeControls(page) {
    const subtitle = page.querySelector("h2 + .muted");
    if (subtitle) subtitle.textContent = "Ищи по названию или создателю. Доступность и поддержка файлов видны в карточке.";

    const wrap = document.createElement("div");
    wrap.className = "mp-tools";
    wrap.innerHTML = '<label class="mp-search"><svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="6.5"></circle><path d="m16 16 4 4"></path></svg><input id="modelSearch" type="search" autocomplete="off" spellcheck="false" placeholder="Название модели или создатель" aria-label="Поиск по моделям и создателям"><button type="button" class="mp-clear" aria-label="Очистить поиск" hidden><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m6 6 12 12M18 6 6 18"></path></svg></button></label>' +
      '<div class="mp-filter-row" role="group" aria-label="Фильтр моделей">' + Object.keys(filterLabels).map((key) => '<button type="button" class="mp-filter' + (key === "all" ? " on" : "") + '" data-filter="' + key + '" aria-pressed="' + (key === "all") + '">' + escapeHTML(filterLabels[key]) + '</button>').join("") + '</div>' +
      '<div class="mp-result-count" aria-live="polite"></div>';
    const tabs = page.querySelector("#provTabs");
    if (tabs) tabs.insertAdjacentElement("beforebegin", wrap);
    else page.appendChild(wrap);

    controls = wrap;
    resultCount = wrap.querySelector(".mp-result-count");
    const input = wrap.querySelector("#modelSearch");
    const clear = wrap.querySelector(".mp-clear");
    input.addEventListener("input", () => {
      const wasSearching = !!currentQuery;
      currentQuery = input.value.trim();
      clear.hidden = !currentQuery;
      if (!currentQuery && wasSearching) resetMainList();
      else renderList();
    });
    clear.addEventListener("click", () => {
      input.value = "";
      currentQuery = "";
      clear.hidden = true;
      input.focus();
      resetMainList();
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && currentQuery) {
        input.value = "";
        currentQuery = "";
        clear.hidden = true;
        resetMainList();
      }
    });
    wrap.querySelectorAll(".mp-filter").forEach((button) => {
      button.addEventListener("click", () => {
        currentFilter = button.getAttribute("data-filter") || "all";
        wrap.querySelectorAll(".mp-filter").forEach((item) => {
          const active = item === button;
          item.classList.toggle("on", active);
          item.setAttribute("aria-pressed", active ? "true" : "false");
        });
        renderList();
      });
    });
  }

  function updateProviderCounts() {
    if (!controls || !modelList) return;
    document.querySelectorAll("#provTabs .prov-tab").forEach((tab) => {
      const provider = tab.getAttribute("data-prov");
      let count = tab.querySelector(".mp-provider-count");
      if (!count) {
        count = document.createElement("span");
        count.className = "mp-provider-count";
        tab.appendChild(count);
      }
      const countText = String(catalogModels.filter((model) => model.provider === provider).length);
      if (count.textContent !== countText) count.textContent = countText;
      const label = "моделей: " + countText;
      if (count.getAttribute("aria-label") !== label) count.setAttribute("aria-label", label);
    });
  }

  function enhanceProviderCards() {
    if (!modelList) return;
    const cards = Array.from(modelList.querySelectorAll(".mcard:not(.mp-global)"));
    cards.forEach((card) => {
      const id = card.getAttribute("data-id");
      const model = catalog.get(id);
      if (!model) return;
      if (!card.classList.contains("mp-enhanced")) {
        const avatar = document.createElement("span");
        avatar.className = "mp-avatar";
        avatar.setAttribute("aria-hidden", "true");
        const image = document.createElement("img");
        image.src = ASSET_ROOT + brandFor(model) + ".svg";
        image.alt = "";
        image.loading = "lazy";
        const fallback = document.createElement("span");
        fallback.className = "mp-avatar-fallback";
        fallback.textContent = "AI";
        fallback.hidden = true;
        avatar.append(image, fallback);
        card.insertBefore(avatar, card.firstElementChild);
        card.classList.add("mp-enhanced");
        image.addEventListener("error", () => { image.hidden = true; fallback.hidden = false; }, { once: true });
      }

      const name = card.querySelector(".nm");
      if (name) {
        name.querySelectorAll(".mp-pill").forEach((pill) => pill.remove());
        if (model.multimodal) name.insertAdjacentHTML("beforeend", pillHTML("Мультимодальная", "mp-media"));
        if (model.available === false) name.insertAdjacentHTML("beforeend", pillHTML("Недоступна", "mp-status"));
      }
      const description = card.querySelector(".ds");
      if (description) {
        description.textContent = model.available === false
          ? (plainText(model.status_short) || "Сейчас недоступна")
          : (model.multimodal ? "Принимает изображения и другие файлы" : "Текстовая модель");
      }
      const meta = card.querySelector(".model-meta");
      if (meta) {
        const rating = formatRating(model.rating);
        meta.textContent = [formatParams(model), plainText(model.creator), rating].filter(Boolean).join(" · ");
      }
      card.classList.toggle("mp-unavailable", model.available === false);
      card.setAttribute("aria-disabled", model.available === false ? "true" : "false");
    });
    installAvatarFallbacks(modelList);
    applyProviderFilter();
  }

  function applyProviderFilter() {
    if (!modelList || currentQuery) return;
    const cards = Array.from(modelList.querySelectorAll(".mcard:not(.mp-global)"));
    let visible = 0;
    cards.forEach((card) => {
      const model = catalog.get(card.getAttribute("data-id"));
      const show = !model || matchesFilter(model);
      card.hidden = !show;
      if (show) visible++;
    });
    let empty = modelList.querySelector(".mp-filter-empty");
    if (!empty) {
      empty = document.createElement("div");
      empty.className = "empty mp-filter-empty";
      empty.textContent = "Нет моделей с таким фильтром";
      modelList.appendChild(empty);
    }
    empty.hidden = visible > 0 || cards.length === 0;
    if (resultCount) {
      const provider = document.querySelector("#provTabs .prov-tab.on");
      const providerNameText = provider ? providerName(provider.getAttribute("data-prov")) : "Модели";
      const total = catalogModels.filter((model) => !provider || model.provider === provider.getAttribute("data-prov")).length;
      resultCount.textContent = visible + " из " + total + " · " + providerNameText;
    }
  }

  function normalizedQuery(value) {
    return plainText(value).toLocaleLowerCase("ru").replace(/\s+/g, " ");
  }

  function searchModels() {
    const query = normalizedQuery(currentQuery);
    let list = catalogModels.filter((model) => matchesFilter(model) && modelSearchText(model).includes(query));
    list.sort((left, right) => {
      const leftName = plainText(left.name).toLocaleLowerCase("ru");
      const rightName = plainText(right.name).toLocaleLowerCase("ru");
      const leftStarts = leftName.startsWith(query) ? 1 : 0;
      const rightStarts = rightName.startsWith(query) ? 1 : 0;
      if (leftStarts !== rightStarts) return rightStarts - leftStarts;
      if ((left.available !== false) !== (right.available !== false)) return left.available === false ? 1 : -1;
      return leftName.localeCompare(rightName, "ru");
    });
    return list;
  }

  function renderGlobalResults() {
    if (!modelList) return;
    const results = searchModels();
    modelList.innerHTML = results.length
      ? results.map(resultCardHTML).join("")
      : '<div class="empty mp-search-empty">Ничего не найдено. Попробуй название модели или её создателя.</div>';
    modelList.classList.add("mp-searching");
    installAvatarFallbacks(modelList);
    if (resultCount) resultCount.textContent = "Найдено " + results.length + " из " + catalogModels.length;
  }

  function activeProviderTab() {
    return document.querySelector("#provTabs .prov-tab.on");
  }

  function resetMainList() {
    modelList.classList.remove("mp-searching");
    const tab = activeProviderTab();
    if (tab) tab.click();
    else refreshList();
  }

  function renderList() {
    if (!modelList) return;
    if (currentQuery) {
      renderGlobalResults();
      return;
    }
    modelList.classList.remove("mp-searching");
    enhanceProviderCards();
  }

  function refreshList() {
    if (!modelList) return;
    updateProviderCounts();
    if (currentQuery) renderGlobalResults();
    else enhanceProviderCards();
  }

  function queueRefresh() {
    if (refreshQueued) return;
    refreshQueued = true;
    Promise.resolve().then(() => {
      refreshQueued = false;
      if (currentQuery) {
        const hasGlobalResults = !!modelList.querySelector(".mcard.mp-global, .mp-search-empty");
        if (!hasGlobalResults) renderGlobalResults();
      } else {
        enhanceProviderCards();
      }
      updateProviderCounts();
    });
  }

  function onModelClick(event) {
    const card = event.target.closest("#modelList .mcard");
    if (!card) return;
    const model = catalog.get(card.getAttribute("data-id"));
    if (model && model.available === false) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    if (!card.classList.contains("mp-global")) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const provider = card.getAttribute("data-provider");
    const id = card.getAttribute("data-id");
    const tab = Array.from(document.querySelectorAll("#provTabs .prov-tab"))
      .find((item) => item.getAttribute("data-prov") === provider);
    if (!tab || tab.classList.contains("limited")) return;
    const savedQuery = currentQuery;
    currentQuery = "";
    modelList.classList.remove("mp-searching");
    tab.click();
    window.requestAnimationFrame(() => {
      const original = Array.from(document.querySelectorAll("#modelList .mcard:not(.mp-global)"))
        .find((item) => item.getAttribute("data-id") === id);
      if (original) original.click();
      currentQuery = savedQuery;
      if (!original) renderGlobalResults();
    });
  }

  function mount() {
    modelList = document.getElementById("modelList");
    const page = document.querySelector("#view-models .models-page");
    if (!modelList || !page) return;
    makeControls(page);
    document.addEventListener("click", onModelClick, true);
    observer = new MutationObserver(queueRefresh);
    observer.observe(modelList, { childList: true, subtree: true });
    const tabs = document.getElementById("provTabs");
    if (tabs) {
      new MutationObserver(updateProviderCounts).observe(tabs, { childList: true, subtree: true });
    }
    refreshList();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount, { once: true });
  else mount();
})();
