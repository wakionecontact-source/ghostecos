import 'package:flutter/material.dart';

import '../../shared/theme/app_theme.dart';
import 'login_screen.dart';
import 'register_screen.dart';

import 'package:ghost/theme.dart';
/// Стартовый экран: войти / создать аккаунт.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  void _go(BuildContext context, Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: const Icon(Icons.shield_moon, size: 48, color: GE.text),
              ),
              const SizedBox(height: 24),
              const Text(
                'GhostChat',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Приватный мессенджер.\nE2E-шифрование. Без слежки.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.sub, height: 1.5),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => _go(context, const RegisterScreen()),
                child: const Text('Создать аккаунт'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _go(context, const LoginScreen()),
                child: const Text(
                  'Войти',
                  style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
