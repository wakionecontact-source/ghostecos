import 'package:flutter/material.dart';

import '../../core/storage/secure_store.dart';
import '../../shared/theme/app_theme.dart';
import '../home/home_shell.dart';
import 'welcome_screen.dart';

import 'package:ghost/theme.dart';
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final token = await SecureStore.I.token;
    // небольшая пауза, чтобы splash не мигал
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final Widget next =
        (token != null && token.isNotEmpty) ? const HomeShell() : const WelcomeScreen();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => next),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    blurRadius: 32,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.shield_moon, size: 44, color: GE.text),
            ),
            const SizedBox(height: 20),
            const Text(
              'GhostChat',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppColors.text,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Общение без следов',
              style: TextStyle(fontSize: 13, color: AppColors.sub),
            ),
            const SizedBox(height: 32),
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}
