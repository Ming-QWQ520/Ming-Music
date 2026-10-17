/// 应用根 Widget：主题模式 + 路由入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/settings/providers/settings_providers.dart';
import 'features/shell/presentation/main_scaffold.dart';

class MingMusicApp extends ConsumerWidget {
  const MingMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: AppTitle.text,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const <Locale>[
        Locale('zh'),
        Locale('en'),
      ],
      locale: const Locale('zh'),
      home: const MainScaffold(),
    );
  }
}

class AppTitle {
  AppTitle._();

  static const String text = 'MingMusic';
}
