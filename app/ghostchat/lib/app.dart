import 'package:flutter/material.dart';

import 'features/auth/splash_screen.dart';
import 'shared/theme/app_theme.dart';

class GhostChatApp extends StatelessWidget {
  const GhostChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostChat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const SplashScreen(),
    );
  }
}
