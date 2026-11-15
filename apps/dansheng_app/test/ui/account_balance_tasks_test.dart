import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
    'Account switching, card balance refresh, jobs listing, and system permissions',
    (WidgetTester tester) async {
      final mockBridge = MockDanshengBridge();
      mockBridge.accountId = 'init_user_100';
      mockBridge.balanceData = {
        'balance': '125.60',
        'currency': 'CNY',
        'updated_at': '2026-11-08 13:00',
      };
      mockBridge.jobs = [
        {
          'id': 'job_alpha',
          'task_id': 'job_alpha',
          'state': 'scheduled',
          'plugin_id': 'org.example.job',
          'wake_up': {'scheduled': true, 'run_at': '2026-11-08 14:00'},
          'action': '定时数据备份',
        },
      ];

      final client = DanshengClient(bridge: mockBridge);
      final controller = DanshengController(client: client);
      await controller.initialize();

      await tester.pumpWidget(
        buildTestApp(
          home: HomeShell(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // 1. Wallet and Account Actions under eHall
      expect(find.text('eHall').first, findsOneWidget);

      // Balance remains on its detail page; the eHall entry stays one line.
      await controller.refreshBalance();
      await tester.pumpAndSettle();
      expect(find.textContaining('125.60'), findsNothing);

      // Open AccountBalanceScreen via toolbar button
      await tester.tap(find.byTooltip('账号与校园卡'));
      await tester.pumpAndSettle();

      expect(find.text('账号与卡包'), findsOneWidget);
      expect(find.text('init_user_100'), findsOneWidget);
      expect(find.text('125.60'), findsOneWidget);
      expect(find.text('CNY'), findsOneWidget);

      // Switch account dialog
      await tester.tap(find.text('切换'));
      await tester.pumpAndSettle();

      expect(find.text('选择校园账号'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'init_user_100'),
        'student_2026',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      // Verify setAccount was called on native host
      final setAccountCall = mockBridge.invocationLog.firstWhere(
        (l) => l['command'] == HostCommand.setAccount,
      );
      expect(setAccountCall['params']['account_id'], 'student_2026');
      expect(find.text('已切换到账号：student_2026'), findsOneWidget);

      // Return back to eHall
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pop();
      await tester.pumpAndSettle();

      // 2. Jobs under 插件 top button tooltip 定时任务
      await tester.tap(find.text('插件'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('定时任务'));
      await tester.pumpAndSettle();

      expect(find.text('任务调度中心'), findsOneWidget);
      expect(find.text('job_alpha'), findsOneWidget);
      expect(find.text('已设闹钟 (待唤醒)'), findsOneWidget);
      expect(find.text('所属：org.example.job'), findsOneWidget);

      // Tap sync events
      await tester.tap(find.byIcon(Icons.sync));
      await tester.pumpAndSettle();

      final eventsCall = mockBridge.invocationLog.firstWhere(
        (l) => l['command'] == HostCommand.events,
      );
      expect(eventsCall, isNotNull);

      // Return back from TasksScreen
      navigator.pop();
      await tester.pumpAndSettle();

      // 3. Settings under eHall toolbar
      await tester.tap(find.text('eHall'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      expect(find.text('设置'), findsOneWidget);
      expect(find.text('准时提醒'), findsOneWidget);
      expect(find.text('前往设置'), findsOneWidget);

      // Tap exact alarm setting
      await tester.tap(find.text('前往设置'));
      await tester.pumpAndSettle();

      final alarmCall = mockBridge.invocationLog.firstWhere(
        (l) => l['command'] == HostCommand.openAlarmSettings,
      );
      expect(alarmCall, isNotNull);

      // Tap notifications request
      await tester.tap(find.text('授权通知'));
      await tester.pumpAndSettle();

      final notifCall = mockBridge.invocationLog.firstWhere(
        (l) => l['command'] == HostCommand.requestNotifications,
      );
      expect(notifCall, isNotNull);

      // Verify theme toggle
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(controller.themeMode, ThemeMode.dark);
    },
  );
}
