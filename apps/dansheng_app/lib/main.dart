import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'ui/core/dansheng_client.dart';
import 'ui/core/dansheng_state.dart';
import 'ui/screens/home_shell.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final client = DanshengClient();
  final controller = DanshengController(client: client);
  runApp(DanshengApp(controller: controller));
  unawaited(controller.initialize());
}

/// Root application widget for Dansheng.
class DanshengApp extends StatefulWidget {
  final DanshengController controller;

  const DanshengApp({super.key, required this.controller});
  @override
  State<DanshengApp> createState() => _DanshengAppState();
}

class _DanshengAppState extends State<DanshengApp> {
  DanshengController get controller => widget.controller;
  Timer? timer;
  bool polling = false;

  /// Stays on through both setup steps, even once the UIS password is saved.
  bool onboarding = false;
  late final AppLifecycleListener lifecycle;
  void start() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (polling || !controller.isInitialized) return;
      polling = true;
      try {
        await controller.pollIncrementalEvents();
      } finally {
        polling = false;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    start();
    lifecycle = AppLifecycleListener(
      onHide: () => timer?.cancel(),
      onShow: start,
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.needsSetup) onboarding = true;
        return MaterialApp(
          title: '旦生',
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: controller.themeMode,
          builder: (context, child) {
            // Apply accessible font scale
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(
                  MediaQuery.textScalerOf(context).scale(16) /
                      16 *
                      controller.textScale,
                ),
              ),
              child: child!,
            );
          },
          home: onboarding
              ? OnboardingScreen(
                  controller: controller,
                  onFinished: () => setState(() => onboarding = false),
                )
              : HomeShell(controller: controller),
        );
      },
    );
  }
}
