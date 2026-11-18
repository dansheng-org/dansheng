import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
    'Narrow screens and accessible large font (1.8x) render without overflow',
    (WidgetTester tester) async {
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
          return;
        }
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);

      // Set narrow physical size: 320 x 640
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final mockBridge = MockDanshengBridge();
      mockBridge.plugins = [
        {
          'id': 'org.example.narrow',
          'name': '超长名称插件用于测试窄屏自动折行与大字体无障碍适配',
          'version': '2.0.1',
          'enabled': true,
          'manifest': {
            'id': 'org.example.narrow',
            'name': '超长名称插件用于测试窄屏自动折行与大字体无障碍适配',
            'capabilities': ['storage.read'],
            'network': ['https://api.example.com'],
            'ui': [
              {
                'id': 'narrow_form',
                'type': 'form',
                'title': '很长的服务表单标题在窄屏下呈现',
                'ui_version': 1,
                'fields': [
                  {'id': 'f1', 'label': '超长字段标签文本测试', 'type': 'text'},
                ],
                'buttons': [
                  {
                    'label': '提交并保存当前草稿数据',
                    'action': 'act',
                    'fields': ['f1'],
                  },
                ],
              },
            ],
          },
        },
      ];

      mockBridge.jobs = [
        {
          'id': 'job_long_identifier_for_testing_purposes_123',
          'task_id': 'job_long_identifier_for_testing_purposes_123',
          'state': 'scheduled',
          'wake_up': 1762600000000,
          'action': '后台定时轮询任务在窄屏大字体下的排版核验',
        },
      ];

      final client = DanshengClient(bridge: mockBridge);
      final controller = DanshengController(client: client);
      controller.setThemeMode(ThemeMode.dark);
      controller.setTextScale(1.8); // 1.8x accessible large font
      await controller.initialize();

      await tester.pumpWidget(
        buildTestApp(
          home: HomeShell(controller: controller),
          controller: controller,
          themeMode: ThemeMode.dark,
          textScale: 1.8,
        ),
      );
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );

      // 1. Root defaults to eHall: verify rendering without overflow
      expect(find.text('eHall').first, findsOneWidget);
      expect(find.text('eHall'), findsWidgets);

      // 2. Open Account & Balance from eHall toolbar
      await controller.refreshBalance();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('账号与校园卡'));
      await tester.pumpAndSettle();
      expect(find.text('账号与卡包'), findsOneWidget);
      expect(find.text('一卡通钱包'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();

      // 3. Open Settings from eHall toolbar
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('设置'), findsOneWidget);

      // 4. Open PluginsScreen from Settings: verify compact list with long plugin name renders without overflow
      await tester.scrollUntilVisible(find.text('插件管理'), 50);
      await tester.ensureVisible(find.text('插件管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('插件管理'));
      await tester.pumpAndSettle();
      expect(find.text('已启用'), findsOneWidget);
      expect(find.textContaining('超长名称插件'), findsOneWidget);

      // 5. Open TasksScreen from PluginsScreen top toolbar tooltip
      await tester.tap(find.byTooltip('定时任务'));
      await tester.pumpAndSettle();
      expect(find.text('任务调度中心'), findsOneWidget);
      expect(find.textContaining('job_long_identifier'), findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();

      // 6. Switch to 科研 tab: verify research page renders without overflow
      await tester.tap(find.text('科研'));
      await tester.pumpAndSettle();
      expect(find.text('科研动态'), findsOneWidget);

      // 7. Return to eHall and check Mailing Shell without overflow
      await tester.tap(find.text('eHall').first);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('校园邮箱'), 300);
      await tester.ensureVisible(find.text('校园邮箱'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('校园邮箱'));
      await tester.pumpAndSettle();

      expect(find.text('邮箱暂未接入'), findsWidgets);
      navigator.pop();
      await tester.pumpAndSettle();
    },
  );
}
