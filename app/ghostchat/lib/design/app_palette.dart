/// Единая палитра GhostChat.
///
/// Источник: лендинг GhostEcos / v2 social.
/// Правила:
///  • фон и поверхности — непрозрачные нейтральные;
///  • фиолетовый — только акцент, не заливка;
///  • границ нет (border-токены прозрачные);
///  • матовое стекло — только для точечных поверхностей (навбар, шторки),
///    поэтому glass-токены живут отдельно от обычных surface-токенов.
library;

import 'package:flutter/material.dart';

abstract final class AppPalette {
  AppPalette._();

  // ── База ────────────────────────────────────────────────────────────────
  static const bg = Color(0xFF020617);
  static const bgDeep = Color(0xFF060A1A);

  /// Обычная непрозрачная поверхность: карточки, строки, панели.
  static const surface = Color(0xFF0F172A);

  /// Приподнятая поверхность: вложенные карточки, поповеры, выбранные строки.
  static const surfaceElevated = Color(0xFF1E293B);

  /// Нажатие/ховер на поверхности.
  static const surfacePressed = Color(0xFF273449);

  // ── Текст ───────────────────────────────────────────────────────────────
  static const text = Color(0xFFF1F5F9);
  static const textSecondary = Color(0xFF94A3B8);
  static const textMuted = Color(0xFF64748B);

  // ── Акцент ──────────────────────────────────────────────────────────────
  static const accent = Color(0xFFA855F7);
  static const accentDeep = Color(0xFF7C3AED);

  /// Сплошная тёмно-фиолетовая подложка для выбранных состояний.
  static const accentSoft = Color(0xFF2A163D);

  /// Текст/иконка на акцентной заливке.
  static const onAccent = Color(0xFFFFFFFF);

  // ── Семантика ───────────────────────────────────────────────────────────
  static const success = Color(0xFF4ADE80);
  static const warning = Color(0xFFFBBF24);
  static const danger = Color(0xFFF87171);
  static const info = Color(0xFF60A5FA);

  // ── Реакции соцсети (единый набор из палитры) ───────────────────────────
  static const reactionHeart = danger;
  static const reactionFire = Color(0xFFFB923C);
  static const reactionLaugh = Color(0xFFFACC15);
  static const reactionSad = info;
  static const reactionClap = Color(0xFFF59E0B);
  static const reactionEyes = accent;

  // ── Стекло (только точечно) ─────────────────────────────────────────────
  static const glassFill = Color(0x8C0F172A); // rgba(15,23,42,0.55)
  static const glassFillStrong = Color(0xC70F172A); // rgba(15,23,42,0.78)
  static const glassBorder = Color(0x00000000);

  // ── Границы (по дизайну их нет) ─────────────────────────────────────────
  static const border = Color(0x00000000);
  static const borderStrong = Color(0x00000000);
  static const glow = Color(0x00000000);

  // ── Оверлеи/тени ────────────────────────────────────────────────────────
  static const overlayWeak = Color(0x3DFFFFFF); // white 24%
  static const overlayMedium = Color(0x8AFFFFFF); // white 54%
  static const overlayStrong = Color(0xB3FFFFFF); // white 70%
  static const scrimFaint = Color(0x42000000); // black 26%
  static const scrimDim = Color(0x55000000); // black 33%
  static const scrimMedium = Color(0x73000000); // black 45%
  static const scrim = Color(0x99000000); // black 60%
  static const scrimSoft = Color(0x8A000000); // black 54%
  static const scrimStrong = Color(0xDE000000); // black 87%
  static const scrimHeavy = Color(0xCC000000); // black 80%
  static const scrimDeep = Color(0xE6000000); // black 90%
  static const shadow = Color(0xFF000000);
  static const transparent = Colors.transparent;

  // ── Градиент акцента (только мелкие элементы) ───────────────────────────
  static const accentGradient = LinearGradient(
    colors: [accent, accentDeep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
