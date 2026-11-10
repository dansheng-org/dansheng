import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
    'Journey: Fresh client has zero plugins, defaults eHall, navigates to 插件, and imports .dspack via modal sheet with {}',
    (WidgetTester tester) async {
      final mockBridge = MockDanshengBridge();
      mockBridge.plugins = []; // Fresh client: zero plugins
      mockBridge.accountId = null; // Fresh client: no account set

      final client = DanshengClient(bridge: mockBridge);
      final controller = DanshengController(client: client);
      await controller.initialize();

      await tester.pumpWidget(
        buildTestApp(home: HomeShell(controller: controller)),
      );
      await tester.pumpAndSettle();

      // 1. Root defaults to eHall
      expect(find.text('校园办事'), findsOneWidget);
      expect(find.text('设置账号'), findsWidgets);
      expect(find.text('场馆预约'), findsOneWidget);

      // Verify five bottom navigation labels
      expect(find.text('eHall'), findsWidgets);
      expect(find.text('eLearning'), findsOneWidget);
      expect(find.text('Agent'), findsOneWidget);
      expect(find.text('论坛'), findsOneWidget);
      expect(find.text('插件'), findsOneWidget);

      // Verify lazy pages: PluginsScreen is not loaded initially
      expect(find.text('定时抢场'), findsNothing);

      // 2. Navigate to Tab 4 (插件)
      await tester.tap(find.text('插件'));
      await tester.pumpAndSettle();

      // Verify empty state is displayed on PluginsScreen
      expect(find.text('定时抢场'), findsOneWidget);
      expect(find.text('未安装插件'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '导入插件包'), findsOneWidget);
      expect(find.byTooltip('导入插件包 (.dspack)'), findsOneWidget);
      expect(find.byTooltip('定时任务'), findsOneWidget);

      // 3. Tap import button - opens modal sheet
      await tester.tap(find.widgetWithText(FilledButton, '导入插件包'));
      await tester.pumpAndSettle();

      // Modal sheet comes separately with security guidance
      expect(find.text('导入扩展包'), findsOneWidget);
      expect(find.text('安装后默认关闭，由你启用。'), findsOneWidget);
      expect(find.text('浏览并导入'), findsOneWidget);

      // Tap '浏览并导入' to trigger native document picker with empty payload {}
      await tester.tap(find.text('浏览并导入'));
      await tester.pumpAndSettle();

      // Verify bridge received importPackage command with empty params {}
      final importCall = mockBridge.invocationLog.firstWhere(
        (log) => log['command'] == HostCommand.importPackage,
      );
      expect(importCall['params'], isEmpty);

      // Verify plugin is now displayed as imported in compact list with OFF status
      expect(find.text('导入的插件包'), findsOneWidget);
      expect(find.text('已停用'), findsOneWidget);

      // 4. Tap '定时任务' icon button in PluginsScreen app bar
      await tester.tap(find.byTooltip('定时任务'));
      await tester.pumpAndSettle();
      expect(find.text('任务调度中心'), findsOneWidget);
    },
  );
}
