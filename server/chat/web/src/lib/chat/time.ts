/** Время в секундах Unix. Сервер отдаёт то число, то SQLite-строку UTC. */
export function toUnixSeconds(value: unknown): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.round(value > 1e12 ? value / 1000 : value);
  }
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) return 0;
    if (/^\d+(\.\d+)?$/.test(trimmed)) return toUnixSeconds(Number(trimmed));
    const iso = trimmed.includes('T') ? trimmed : trimmed.replace(' ', 'T');
    const withZone = /(?:Z|[+-]\d{2}:?\d{2})$/.test(iso) ? iso : `${iso}Z`;
    const parsed = Date.parse(withZone);
    return Number.isFinite(parsed) ? Math.round(parsed / 1000) : 0;
  }
  return 0;
}

/** Дата из секунд; 0 и мусор дают null, чтобы UI не печатал «Invalid Date». */
export function dateFromSeconds(ts: number): Date | null {
  if (!ts || !Number.isFinite(ts) || ts <= 0) return null;
  const date = new Date(ts * 1000);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function timeLabel(ts: number): string {
  const date = dateFromSeconds(ts);
  if (!date) return '';
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

export function shortDateLabel(ts: number): string {
  const date = dateFromSeconds(ts);
  if (!date) return '';
  const sameDay = date.toDateString() === new Date().toDateString();
  if (sameDay) return timeLabel(ts);
  return date.toLocaleDateString([], { day: '2-digit', month: '2-digit' });
}

/** Разделитель дней как в приложении: «Сегодня», «Вчера», иначе дата. */
export function dayLabel(ts: number): string {
  const date = dateFromSeconds(ts);
  if (!date) return '';
  const today = new Date();
  const yesterday = new Date();
  yesterday.setDate(today.getDate() - 1);
  const same = (a: Date, b: Date) => a.toDateString() === b.toDateString();
  if (same(date, today)) return 'Сегодня';
  if (same(date, yesterday)) return 'Вчера';
  return date.toLocaleDateString([], { day: '2-digit', month: 'long' });
}

export function dayKey(ts: number): string {
  const date = dateFromSeconds(ts);
  return date ? date.toDateString() : '';
}

/** Время диалога как в списке чатов приложения: сегодня — часы, неделя — день, дальше дата. */
export function dialogTimeLabel(ts: number): string {
  const date = dateFromSeconds(ts);
  if (!date) return '';
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const day = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  const diff = Math.round((today.getTime() - day.getTime()) / 86_400_000);
  if (diff === 0) return timeLabel(ts);
  if (diff > 0 && diff < 7) {
    const week = ['вс', 'пн', 'вт', 'ср', 'чт', 'пт', 'сб'];
    return week[date.getDay()];
  }
  return date.toLocaleDateString([], { day: '2-digit', month: '2-digit' });
}
