const SCOPE_KEY = 'gc.web.scope';

function read(): string {
  try {
    return localStorage.getItem(SCOPE_KEY) ?? '';
  } catch {
    return '';
  }
}

/** Возвращает true, если аккаунт сменился: кеш прошлого аккаунта надо выбросить. */
export function applyScope(userId: string): boolean {
  const previous = read();
  try {
    localStorage.setItem(SCOPE_KEY, userId);
  } catch {
    // Приватный режим может запрещать запись — тогда живём без разделения.
  }
  return previous !== '' && previous !== userId;
}

/** Суффикс для ключей хранилища: у каждого аккаунта свой сейф и свои метки. */
export function scopeSuffix(): string {
  const id = read();
  return id ? `:${id}` : '';
}
