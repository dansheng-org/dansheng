// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/import_panel.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test mock bridge for package import and plugin state tests.
class MockImportBridge implements DanshengBridge {
  final List<Map<String, dynamic>> plugins = [];
  final List<Map<String, dynamic>> invocations = [];
  bool simulateSafCancellation = false;
  bool simulateSafError = false;

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    invocations.add({'command': command, 'params': params});

    switch (command) {
      case HostCommand.info:
        return jsonEncode({'version': '0.2.0', 'core': 'mock'});

      case HostCommand.plugins:
        return jsonEncode(plugins);

      case HostCommand.importPackage:
        if (simulateSafCancellation) {
          throw PlatformException(code: 'Cancelled', message: 'Cancelled');
        }
        if (simulateSafError) {
          throw PlatformException(
            code: 'InvalidPackage',
            message: 'Corrupted archive',
          );
        }
        plugins.add({
          'id': 'official.fudan-sports',
          'name': '复旦体育',
          'version': '1.0.0',
          'enabled': false,
          'manifest': {
            'id': 'official.fudan-sports',
            'name': '复旦体育',
            'version': '1.0.0',
            'capabilities': ['storage.read', 'http.request'],
            'network': ['https://sports.fudan.edu.cn'],
          },
        });
        return jsonEncode({'status': 'installed'});

      case HostCommand.account:
        return jsonEncode({'account_id': 'test_user'});

      case HostCommand.jobs:
        return jsonEncode([]);

      case HostCommand.permissions:
        return jsonEncode({
          'exact_available': true,
          'notifications_available': true,
        });

      default:
        return jsonEncode({'status': 'ok'});
    }
  }
}

Widget createTestApp({
  required DanshengController controller,
  ThemeMode themeMode = ThemeMode.light,
  TextScaler textScaler = TextScaler.noScaling,
  required WidgetBuilder childBuilder,
}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: themeMode,
    home: MediaQuery(
      data: MediaQueryData(textScaler: textScaler),
      child: Scaffold(body: Builder(builder: childBuilder)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockImportBridge mockBridge;
  late DanshengClient client;
  late DanshengController controller;

  setUp(() {
    mockBridge = MockImportBridge();
    client = DanshengClient(bridge: mockBridge);
    controller = DanshengController(client: client);
  });

  group('Modern Extension Importer Bottom Sheet Tests', () {
    testWidgets(
      'Renders flagship Material 3 sheet with icon, Chinese copy, affordance, and CTA',
      (tester) async {
        await tester.pumpWidget(
          createTestApp(
            controller: controller,
            childBuilder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showPluginImporter(ctx, controller),
                child: const Text('Open'),
              ),
            ),
          ),
        );

        // Open bottom sheet
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // Verify extension icon container
        expect(find.byIcon(Icons.extension_rounded), findsOneWidget);

        // Verify concise friendly Chinese copy
        expect(find.text('导入扩展包'), findsOneWidget);
        expect(find.text('安装后默认关闭，由你启用。'), findsOneWidget);

        // Verify selected .dspack file source affordance
        expect(find.byIcon(Icons.file_present_rounded), findsOneWidget);
        expect(find.text('本地插件包'), findsOneWidget);
        expect(find.text('.dspack'), findsOneWidget);
        expect(find.text('从下载目录或文件应用中选择'), findsOneWidget);

        // Verify clear CTA button
        expect(find.text('浏览并导入'), findsOneWidget);
        expect(find.byIcon(Icons.file_open_rounded), findsOneWidget);

        // Verify cancel button
        expect(find.text('取消'), findsOneWidget);
      },
    );

    testWidgets(
      'Tapping CTA launches controller.importPackage() with native SAF and dismisses sheet',
      (tester) async {
        await tester.pumpWidget(
          createTestApp(
            controller: controller,
            childBuilder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showPluginImporter(ctx, controller),
                child: const Text('Open'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // Tap CTA button
        await tester.tap(find.text('浏览并导入'));
        await tester.pumpAndSettle();

        // Sheet should be dismissed
        expect(find.text('导入扩展包'), findsNothing);

        // Verify importPackage was called via bridge
        final importCalls = mockBridge.invocations
            .where((i) => i['command'] == HostCommand.importPackage)
            .toList();
        expect(importCalls.length, 1);

        // SAF call passes empty or null path
        final params = importCalls.first['params'] as Map<String, dynamic>;
        expect(params['path'], isNull);

        // Plugin state updated
        expect(controller.plugins.length, 1);
        expect(controller.plugins.first['id'], 'official.fudan-sports');
        expect(controller.errorMessage, isNull);
      },
    );

    testWidgets(
      'SAF cancellation is handled gracefully without duplicate error prompts',
      (tester) async {
        mockBridge.simulateSafCancellation = true;

        await tester.pumpWidget(
          createTestApp(
            controller: controller,
            childBuilder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showPluginImporter(ctx, controller),
                child: const Text('Open'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // Tap CTA button
        await tester.tap(find.text('浏览并导入'));
        await tester.pumpAndSettle();

        // Sheet dismissed
        expect(find.text('导入扩展包'), findsNothing);

        // Cancellation should NOT leave an error banner in controller
        expect(controller.errorMessage, isNull);

        // No unhandled exceptions thrown
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Tapping Cancel dismisses sheet without calling importPackage',
      (tester) async {
        await tester.pumpWidget(
          createTestApp(
            controller: controller,
            childBuilder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showPluginImporter(ctx, controller),
                child: const Text('Open'),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        // Tap Cancel button
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();

        // Sheet is closed
        expect(find.text('导入扩展包'), findsNothing);

        // No importPackage call
        final importCalls = mockBridge.invocations.where(
          (i) => i['command'] == HostCommand.importPackage,
        );
        expect(importCalls.isEmpty, isTrue);
      },
    );

    testWidgets('Renders properly in Dark Theme', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          controller: controller,
          themeMode: ThemeMode.dark,
          childBuilder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showPluginImporter(ctx, controller),
              child: const Text('Open Dark'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dark'));
      await tester.pumpAndSettle();

      expect(find.text('导入扩展包'), findsOneWidget);
      expect(find.text('浏览并导入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Adapts to large font scaling without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          controller: controller,
          textScaler: const TextScaler.linear(1.8),
          childBuilder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showPluginImporter(ctx, controller),
              child: const Text('Open Large'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Large'));
      await tester.pumpAndSettle();

      expect(find.text('导入扩展包'), findsOneWidget);
      expect(find.text('浏览并导入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Adapts cleanly to small phone screen dimensions (320x568)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320 * 2.0, 568 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        createTestApp(
          controller: controller,
          childBuilder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showPluginImporter(ctx, controller),
              child: const Text('Open Small'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Small'));
      await tester.pumpAndSettle();

      expect(find.text('导入扩展包'), findsOneWidget);
      expect(find.text('浏览并导入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
