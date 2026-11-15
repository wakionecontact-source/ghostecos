import { requestJson } from './http';

/** Публичный профиль текущего пользователя — как в приложении. */
export interface MeProfile {
  id: number;
  username: string;
  display_name: string;
  about?: string | null;
  avatar_url?: string | null;
  is_admin?: boolean;
  is_moderator?: boolean;
  posts_count?: number;
  followers_count?: number;
  following_count?: number;
  likes_received?: number;
  likes_given?: number;
}

/** Результат поиска пользователей для нового чата. */
export interface UserHit {
  username: string;
  display_name: string;
  has_keys: boolean;
}

export function fetchMe(token: string): Promise<MeProfile> {
  return requestJson<MeProfile>('/api/soc/me', { token });
}

export function searchUsers(token: string, query: string): Promise<{ results: UserHit[] }> {
  return requestJson<{ results: UserHit[] }>(
    `/api/chat/users/search?q=${encodeURIComponent(query)}`,
    { token },
  );
}

/** Правка публичного профиля — только отображаемые поля, без смены пароля. */
export function updateProfile(
  token: string,
  body: { display_name?: string; about?: string },
): Promise<{ status: string }> {
  return requestJson<{ status: string }>('/api/soc/me/profile', {
    token,
    method: 'PATCH',
    body,
  });
}

export function uploadAvatar(token: string, file: File): Promise<{ avatar_url: string }> {
  const form = new FormData();
  form.append('file', file, file.name);
  return requestJson<{ avatar_url: string }>('/api/soc/me/avatar', { token, form });
}

export function deleteAvatar(token: string): Promise<{ ok: boolean }> {
  return requestJson<{ ok: boolean }>('/api/soc/me/avatar', { token, method: 'DELETE' });
}
