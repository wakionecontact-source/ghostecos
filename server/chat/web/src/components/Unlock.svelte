<script lang="ts">
  import { onMount } from 'svelte';
  import type { ChatClient, IdentityMe, MyKeys } from '../lib/api/chat';
  import { unlockAccount } from '../lib/auth/account';
  import { saveDeviceVault } from '../lib/auth/vault';
  import { unlockV2, bindDeviceWithMnemonic, ReplaceRequiredError, type V2Keys } from '../lib/chat/keys';
  import {
    generateKeys,
    publishAccountKey,
    publishKeys,
    type KeyStorageMode,
  } from '../lib/chat/provision';
  import { generateAccountKey, type AccountKey } from '../lib/crypto/account-key';

  interface Props {
    api: ChatClient;
    username: string;
    hasVault: boolean;
    onready: (account: AccountKey, v2: V2Keys | null) => void;
    onlogout: () => void;
  }

  let { api, username, hasVault, onready, onlogout }: Props = $props();

  let keys = $state<MyKeys | null>(null);
  let identity = $state<IdentityMe | null>(null);
  let mode = $state<KeyStorageMode>('server');
  let step = $state<'choice' | 'password'>('choice');
  let password = $state('');
  let phrase = $state('');
  let busy = $state(false);
  let error = $state('');
  let replaceNeeded = $state(false);

  const hasServerKey = $derived(!!keys?.encrypted_private_key && !!keys?.key_salt);
  const hasIdentity = $derived(!!identity?.identity_pub);
  // Пароль нужен для серверной копии и для восстановления уже созданной identity.
  const needPassword = $derived(mode === 'server' || hasIdentity);
  // Серверной копии identity нет — новое устройство привязывается seed-фразой.
  const needPhrase = $derived(hasIdentity && !identity?.identity_priv_encrypted);
  const phraseReady = $derived(phrase.trim().split(/\s+/).length === 12);

  onMount(async () => {
    try {
      const [keyState, identityState] = await Promise.all([
        api.myKeys(),
        api.myIdentity().catch(() => null),
      ]);
      keys = keyState;
      identity = identityState;
      if (identityState?.identity_pub && !keyState.encrypted_private_key) {
        // Identity уже опубликована: её seed открывается только паролем.
        step = 'password';
      }
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось проверить ключи';
    }
  });

  async function unlock(replace = false) {
    busy = true;
    error = '';
    try {
      const account = await unlockAccount(api, password, username);
      // Identity без серверной копии открывается только seed-фразой, как в приложении.
      const v2 = needPhrase
        ? await bindDeviceWithMnemonic(api, username, phrase, identity!.identity_pub!, replace)
        : await unlockV2(api, { password, username, replace }).catch((cause) => {
            if (cause instanceof ReplaceRequiredError) throw cause;
            return null;
          });
      replaceNeeded = false;
      onready(account, v2);
    } catch (cause) {
      if (cause instanceof ReplaceRequiredError) replaceNeeded = true;
      error = cause instanceof Error ? cause.message : 'Не удалось разблокировать ключ';
    } finally {
      busy = false;
    }
  }

  function next() {
    error = '';
    if (needPassword) {
      step = 'password';
      return;
    }
    void create();
  }

  /** Ключи создаются на устройстве, затем публикуются в выбранном режиме. */
  async function create(replace = false) {
    busy = true;
    error = '';
    try {
      let account: AccountKey;
      let v2: V2Keys;

      if (hasIdentity) {
        // identity уже на сервере: без серверной копии её открывает seed-фраза.
        const recovered = needPhrase
          ? await bindDeviceWithMnemonic(api, username, phrase, identity!.identity_pub!, replace)
          : await unlockV2(api, { password, username, replace });
        if (!recovered) throw new Error('Не удалось открыть сохранённую identity этим паролем');
        account = await generateAccountKey();
        await publishAccountKey(api, username, account, mode, password, replace);
        await saveDeviceVault({ accountPkcs8: account.pkcs8, accountPublic: account.publicKey });
        v2 = recovered;
      } else {
        const generated = await generateKeys();
        await publishKeys(api, username, generated, mode, password, replace);
        account = generated.account;
        v2 = generated.v2;
      }
      replaceNeeded = false;
      onready(account, v2);
    } catch (cause) {
      error = cause instanceof Error ? cause.message : 'Не удалось создать ключ';
    } finally {
      busy = false;
    }
  }
</script>

<main class="screen">
  <header class="topbar">
    <a class="brand" href="/home">Ghost<em>Chat</em></a>
    <span class="tag">ключ аккаунта</span>
  </header>

  <section class="content">
    <div class="card entry fade-in">
      {#if !keys}
        <h1>Проверяем ключ…</h1>
      {:else if hasServerKey}
        <h1>Разблокировка</h1>
        <p class="note">
          {#if needPhrase}
            Ключ аккаунта хранится на сервере в зашифрованном виде, а identity — только на твоих
            устройствах. Введи пароль и seed-фразу из приложения (Настройки → Seed-фраза v2).
          {:else}
            Ключ шифрования хранится на сервере в зашифрованном виде. Пароль тот же, что в
            приложении.
          {/if}
        </p>
        <label>
          Пароль аккаунта
          <input class="field" type="password" bind:value={password} autocomplete="current-password" />
        </label>
        {#if needPhrase}
          <label>
            Seed-фраза (12 слов)
            <input class="field" bind:value={phrase} autocomplete="off" spellcheck="false" />
          </label>
        {/if}
        <button
          class="button primary"
          onclick={() => unlock()}
          disabled={busy || !password || (needPhrase && !phraseReady)}
        >
          {busy ? 'Расшифровываем…' : 'Взять ключ'}
        </button>
        {#if hasVault}
          <p class="fine">После разблокировки пароль больше не понадобится на этом устройстве.</p>
        {/if}
      {:else if step === 'choice'}
        <h1>Ключ шифрования</h1>
        <p class="note">
          Сообщения шифруются ключом, который есть только у тебя. Что с ним делать при переустановке
          или смене устройства?
        </p>

        <button class="option" class:selected={mode === 'server'} onclick={() => (mode = 'server')}>
          <span class="radio" aria-hidden="true"></span>
          <span class="body">
            <span class="title">Копия на сервере <em>Рекомендуется</em></span>
            <span class="hint">
              Ключ, зашифрованный паролем аккаунта, хранится на сервере. Переустановил → ввёл пароль
              → переписка на месте. Сам ключ сервер прочитать не может.
            </span>
          </span>
        </button>

        <button class="option" class:selected={mode === 'local'} onclick={() => (mode = 'local')}>
          <span class="radio" aria-hidden="true"></span>
          <span class="body">
            <span class="title">Только на устройстве</span>
            <span class="hint">
              Максимум приватности: ключ никогда не покидает браузер. Но при смене устройства или
              очистке данных переписка теряется безвозвратно.
            </span>
          </span>
        </button>

        <button class="button primary" onclick={next} disabled={busy}>
          Далее
        </button>
      {:else}
        <h1>{mode === 'server' && !hasIdentity ? 'Пароль аккаунта' : 'Открыть ключ'}</h1>
        <p class="note">
          {#if needPhrase}
            На сервере уже сохранена identity этого аккаунта, но её копии там нет. Введи пароль и
            seed-фразу из приложения (Настройки → Seed-фраза v2).
          {:else if hasIdentity}
            На сервере уже сохранена identity этого аккаунта. Введи пароль, чтобы открыть её на этом
            устройстве.
          {:else}
            Вход идёт через GhostID, и пароль в чат не передаётся. Он нужен один раз — чтобы
            зашифровать копию ключа перед отправкой на сервер.
          {/if}
        </p>
        <label>
          Пароль аккаунта
          <input
            class="field"
            type="password"
            bind:value={password}
            autocomplete="current-password"
            onkeydown={(event) => {
              if (event.key === 'Enter' && password && !busy) void create();
            }}
          />
        </label>
        {#if needPhrase}
          <label>
            Seed-фраза (12 слов)
            <input class="field" bind:value={phrase} autocomplete="off" spellcheck="false" />
          </label>
        {/if}
        <button
          class="button primary"
          onclick={() => create()}
          disabled={busy || !password || (needPhrase && !phraseReady)}
        >
          {busy ? 'Создаём ключ…' : 'Продолжить'}
        </button>
        {#if !hasIdentity}
          <button class="pill" onclick={() => (step = 'choice')}>Назад</button>
        {/if}
      {/if}

      {#if error}
        <p class="error">{error}</p>
      {/if}

      {#if replaceNeeded}
        <p class="fine">
          Ключ этого устройства будет заменён: сообщения, зашифрованные под старый ключ, здесь
          больше не откроются.
        </p>
        <button
          class="button primary"
          onclick={() => (hasServerKey ? unlock(true) : create(true))}
          disabled={busy}
        >
          Заменить ключ
        </button>
      {/if}

      <button class="pill" onclick={onlogout}>Выйти из аккаунта</button>
    </div>
  </section>
</main>

<style>
  .screen {
    display: flex;
    flex-direction: column;
    min-height: 100%;
  }

  .tag {
    color: var(--muted);
    font-size: 12px;
  }

  .content {
    flex: 1;
    display: grid;
    place-items: center;
    padding: 24px 16px;
  }

  .entry {
    display: grid;
    gap: 12px;
    width: min(100%, 440px);
    padding: 22px;
  }

  h1 {
    margin: 0;
    font-size: 20px;
    font-weight: 600;
    letter-spacing: -0.02em;
  }

  .note {
    margin: -6px 0 2px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
  }

  .option {
    display: flex;
    gap: 10px;
    align-items: flex-start;
    padding: 14px;
    border: 1px solid var(--border);
    border-radius: 14px;
    background: var(--card);
    text-align: left;
    white-space: normal;
    height: auto;
  }

  .option:hover {
    background: var(--card);
    border-color: var(--border-strong, var(--border));
  }

  .option.selected {
    border-color: var(--accent, var(--primary, #8b7cf6));
    box-shadow: 0 0 0 1px var(--accent, var(--primary, #8b7cf6)) inset;
  }

  .radio {
    flex: 0 0 auto;
    width: 16px;
    height: 16px;
    margin-top: 2px;
    border: 1.5px solid var(--muted);
    border-radius: 50%;
  }

  .option.selected .radio {
    border-color: var(--accent, var(--primary, #8b7cf6));
    box-shadow: 0 0 0 4px color-mix(in srgb, var(--accent, var(--primary, #8b7cf6)) 22%, transparent);
  }

  .body {
    display: grid;
    gap: 4px;
  }

  .title {
    font-size: 14px;
    font-weight: 600;
  }

  .title em {
    margin-left: 6px;
    padding: 1px 6px;
    border-radius: 6px;
    background: color-mix(in srgb, var(--accent, var(--primary, #8b7cf6)) 18%, transparent);
    color: var(--accent, var(--primary, #8b7cf6));
    font-size: 10px;
    font-style: normal;
    font-weight: 600;
    vertical-align: 1px;
  }

  .hint {
    color: var(--muted);
    font-size: 12.5px;
    line-height: 1.45;
  }

  label {
    display: grid;
    gap: 6px;
    color: var(--muted);
    font-size: 12px;
  }

  .fine {
    margin: 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.5;
  }

  .error {
    margin: 0;
    color: var(--danger);
    font-size: 13px;
  }

  .pill {
    justify-self: start;
    height: auto;
    padding: 4px 0;
    color: var(--muted);
    font-size: 12px;
  }

  .pill:hover {
    background: transparent;
    color: var(--text);
  }
</style>
