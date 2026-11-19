<?php
declare(strict_types=1);

// Настройки выданы GhostStudio для этого приложения.
function ghostid_config(): array {
    return json_decode(base64_decode('__GHOSTID_CONFIG__'), true, 512, JSON_THROW_ON_ERROR);
}

function ghostid_call(string $path, array $body): array {
    $config = ghostid_config();
    $curl = curl_init($config['issuer'] . '/api/sso/managed/' . $path);
    curl_setopt_array($curl, [
        CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($body, JSON_THROW_ON_ERROR),
        CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Accept: application/json'],
        CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_CONNECTTIMEOUT => 4, CURLOPT_TIMEOUT => 10,
        CURLOPT_PROTOCOLS => CURLPROTO_HTTPS, CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2
    ]);
    $text = curl_exec($curl);
    $status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
    curl_close($curl);
    if (!is_string($text) || strlen($text) > 8192 || $status < 200 || $status >= 300) {
        throw new RuntimeException('Не удалось завершить вход');
    }
    return json_decode($text, true, 512, JSON_THROW_ON_ERROR);
}

function ghostid_fail(int $status, string $message): void {
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    echo $message;
}

function ghostid_handle(?callable $onLogin = null): void {
    $config = ghostid_config();
    $cookieName = '__Host-GhostID-' . $config['clientId'];
    $cookieOptions = ['expires' => time() + 600, 'path' => '/', 'secure' => true,
                      'httponly' => true, 'samesite' => 'Lax'];
    header('Cache-Control: no-store');
    header('Referrer-Policy: no-referrer');
    header('X-Content-Type-Options: nosniff');
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'GET') {
        header('Allow: GET'); ghostid_fail(405, 'Нужен запрос GET'); return;
    }
    try {
        $action = $_GET['action'] ?? '';
        if ($action === 'verify') {
            header('Content-Type: text/plain; charset=utf-8'); echo $config['proof']; return;
        }
        if ($action === 'start') {
            $data = ghostid_call('start', ['client_id' => $config['clientId']]);
            $target = parse_url($data['authorization_url'] ?? '');
            $issuer = parse_url($config['issuer']);
            if (!preg_match('/^[A-Za-z0-9_-]{43}$/D', $data['nonce'] ?? '') ||
                !preg_match('/^[A-Za-z0-9_-]{43}$/D', $data['state'] ?? '') ||
                ($target['scheme'] ?? '') !== 'https' || ($target['host'] ?? '') !== $issuer['host'] ||
                ($target['port'] ?? 443) !== ($issuer['port'] ?? 443) ||
                isset($target['user']) || isset($target['pass']) || ($target['path'] ?? '') !== '/v2/auth') {
                throw new RuntimeException('Неверный адрес входа');
            }
            setcookie($cookieName, $data['nonce'], $cookieOptions);
            header('Location: ' . $data['authorization_url'], true, 303); return;
        }
        if ($action !== 'callback') { ghostid_fail(404, 'Страница не найдена'); return; }
        $params = [];
        // Сохраняем проверку повторяющихся параметров, которые PHP иначе объединяет.
        foreach (explode('&', $_SERVER['QUERY_STRING'] ?? '') as $part) {
            [$key, $value] = array_pad(explode('=', $part, 2), 2, '');
            $key = urldecode($key);
            if (array_key_exists($key, $params) || !in_array($key, ['action', 'state', 'iss', 'code', 'error'], true)) {
                ghostid_fail(400, 'Неверный ответ входа'); return;
            }
            $params[$key] = urldecode($value);
        }
        $nonce = $_COOKIE[$cookieName] ?? '';
        if (($params['iss'] ?? '') !== $config['issuer'] ||
            !preg_match('/^[A-Za-z0-9_-]{43}$/D', $params['state'] ?? '') ||
            !preg_match('/^[A-Za-z0-9_-]{43}$/D', $nonce) ||
            (!empty($params['code']) === !empty($params['error'])) ||
            (isset($params['error']) && $params['error'] !== 'access_denied')) {
            ghostid_fail(400, 'Ответ входа не принадлежит этому браузеру. Начни вход заново.'); return;
        }
        $cookieOptions['expires'] = time() - 3600;
        setcookie($cookieName, '', $cookieOptions);
        $body = ['client_id' => $config['clientId'], 'state' => $params['state'], 'nonce' => $nonce, 'iss' => $params['iss']];
        $body[isset($params['code']) ? 'code' : 'error'] = $params['code'] ?? $params['error'];
        $data = ghostid_call('complete', $body);
        if (($data['error'] ?? '') === 'access_denied') { ghostid_fail(403, 'Ты отменил вход через GhostID.'); return; }
        if (($data['client_id'] ?? '') !== $config['clientId'] ||
            !is_string($data['user']['sub'] ?? null) || $data['user']['sub'] === '') throw new RuntimeException();
        $user = array_intersect_key($data['user'], array_flip(['sub', 'username', 'name', 'picture']));
        // Передаём данные в код сайта; он сам решает, что с ними делать.
        if ($onLogin !== null) { $onLogin($user); return; }
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($user, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
    } catch (Throwable $error) {
        ghostid_fail(502, 'Не удалось завершить вход через GhostID. Начни вход заново.');
    }
}

// Здесь можно передать свою функцию, которая получит данные пользователя.
ghostid_handle();
