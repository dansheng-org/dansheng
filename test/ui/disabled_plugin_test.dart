import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
    'Journey: Capabilities visible on card, enable toggle calls native authoritative gate',
    (WidgetTester tester) async {
      final mockBridge = MockDanshengBridge();
      mockBridge.plugins = [
        {
          'id': 'org.example.test-plugin',
          'name': '测试服务插件',
          'version': '1.2.0',
          'enabled': false,
          'manifest': {
            'id': 'org.example.test-plugin',
            'name': '测试服务插件',
            'capabilities': ['storage.read', 'http.request', 'jobs.schedule'],
            'network': ['https://service.example.org'],
            'ui': [
              {
                'id': 'query_form',
                'type': 'form',
                'title': '服务查询表单',
                'ui_version': 1,
                'fields': [],
                'buttons': [],
              },
            ],
          },
        },
      ];

      final client = DanshengClient(bridge: mockBridge);
      final controller = DanshengController(client: client);
      await controller.initialize();

      await tester.pumpWidget(
        buildTestApp(home: HomeShell(controller: controller)),
      );
      await tester.pumpAndSettle();

      // Root defaults to eHall; navigate to 插件 tab
      expect(find.text('eHall').first, findsOneWidget);
      await tester.tap(find.text('插件'));
      await tester.pumpAndSettle();

      // Verify compact plugin card is displayed as disabled
      expect(find.text('测试服务插件'), findsOneWidget);
      expect(find.text('已停用'), findsOneWidget);

      // Verify UI declaration entry is NOT shown when disabled
      expect(find.text('服务查询表单'), findsNothing);

      // Expand compact plugin details tile
      expect(find.text('插件信息'), findsOneWidget);
      await tester.tap(find.text('插件信息'));
      await tester.pumpAndSettle();

      // Verify capability names and network origins are visible
      expect(
        find.textContaining('storage.read · http.request · jobs.schedule'),
        findsOneWidget,
      );
      expect(
        find.textContaining('https://service.example.org'),
        findsOneWidget,
      );
      expect(find.text('卸载插件'), findsOneWidget);

      // Tap switch - calls enablePlugin on native host
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      // Verify enablePlugin command was invoked on native host
      final enableCall = mockBridge.invocationLog.firstWhere(
        (log) => log['command'] == HostCommand.enablePlugin,
      );
      expect(enableCall['params']['plugin_id'], 'org.example.test-plugin');

      // Verify status is now enabled and schema entry is revealed
      expect(find.text('已启用'), findsOneWidget);
      expect(find.text('服务查询表单'), findsOneWidget);

      // Tap switch again to disable
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      final disableCall = mockBridge.invocationLog.firstWhere(
        (log) => log['command'] == HostCommand.disablePlugin,
      );
      expect(disableCall['params']['plugin_id'], 'org.example.test-plugin');
      expect(find.text('已停用'), findsOneWidget);
      expect(find.text('服务查询表单'), findsNothing);
    },
  );
}
