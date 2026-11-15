const PREFS_KEY = 'gc.web.prefs';

export type AccentName = 'lavender' | 'blue' | 'green' | 'pink' | 'amber';

export interface WebPrefs {
  accent: AccentName;
  notifications: boolean;
}

export const ACCENTS: Record<AccentName, { title: string; accent: string; deep: string; from: string; to: string }> = {
  lavender: { title: 'Лаванда', accent: '#b39af4', deep: '#6d4fd0', from: '#6d4fd0', to: '#a285f0' },
  blue: { title: 'Лазурь', accent: '#7fb2ff', deep: '#3c6fd8', from: '#3c6fd8', to: '#78aaff' },
  green: { title: 'Мята', accent: '#7fd6b3', deep: '#2f8f6f', from: '#2f8f6f', to: '#79d0ad' },
  pink: { title: 'Роза', accent: '#f39ac4', deep: '#b4467f', from: '#b4467f', to: '#ef93bd' },
  amber: { title: 'Янтарь', accent: '#f0b877', deep: '#b57a2b', from: '#b57a2b', to: '#efb271' },
};

const DEFAULTS: WebPrefs = { accent: 'lavender', notifications: false };

export function loadPrefs(): WebPrefs {
  try {
    const raw = localStorage.getItem(PREFS_KEY);
    if (!raw) return { ...DEFAULTS };
    const parsed = JSON.parse(raw) as Partial<WebPrefs>;
    return {
      accent: parsed.accent && parsed.accent in ACCENTS ? parsed.accent : DEFAULTS.accent,
      notifications: !!parsed.notifications,
    };
  } catch {
    return { ...DEFAULTS };
  }
}

export function savePrefs(prefs: WebPrefs): void {
  try {
    localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
  } catch {
    // Приватный режим может запрещать запись.
  }
}

/** Акцент применяется переменными, оформление остаётся единым. */
export function applyPrefs(prefs: WebPrefs): void {
  const palette = ACCENTS[prefs.accent] ?? ACCENTS.lavender;
  const root = document.documentElement.style;
  root.setProperty('--accent', palette.accent);
  root.setProperty('--accent-deep', palette.deep);
  root.setProperty('--bubble-mine-from', palette.from);
  root.setProperty('--bubble-mine-to', palette.to);
}
