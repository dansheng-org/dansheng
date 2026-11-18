// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/ehall/ehall_page.dart';
import 'package:dansheng_app/ui/campus/learning/learning_page.dart';
import 'package:dansheng_app/ui/campus/agent/agent_page.dart';
import 'package:dansheng_app/ui/campus/forum/forum_page.dart';
import 'package:dansheng_app/ui/campus/research/research_page.dart';
import 'package:dansheng_app/ui/campus/venues/venue_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/screens/account_balance_screen.dart';
import 'package:dansheng_app/ui/screens/home_shell.dart';
import 'package:dansheng_app/ui/screens/plugins_screen.dart';
import 'package:dansheng_app/ui/screens/schema_screen.dart';
import 'package:dansheng_app/ui/screens/settings_screen.dart';
import 'package:dansheng_app/ui/screens/tasks_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/test_helpers.dart';

void main() {
  group('Campus Five-Tab Navigation & Refactor Suite', () {
    late MockDanshengBridge bridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() async {
      bridge = MockDanshengBridge();
      bridge.accountId = 'student_test_888';
      bridge.balanceData = {
        'balance': '99.50',
        'currency': 'CNY',
        'updated_at': '2026-11-08 15:00',
      };
      client = DanshengClient(bridge: bridge);
      controller = DanshengController(client: client);
      await controller.initialize();
    });

    testWidgets(
      'Root defaults to eHall with 5 bottom destinations and lazy instantiation',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: HomeShell(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Verify bottom navigation bar has the five required labels
        expect(find.text('eHall'), findsWidgets);
        expect(find.text('eLearning'), findsOneWidget);
        expect(find.text('Agent'), findsOneWidget);
        expect(find.text('论坛'), findsOneWidget);
        expect(find.text('科研'), findsOneWidget);

        // Active page is EHallPage
        expect(find.byType(EHallPage), findsOneWidget);
        expect(find.text('eHall'), findsWidgets);

        // Lazy pages: other 4 tabs are not yet in the tree
        expect(find.byType(LearningPage), findsNothing);
        expect(find.byType(AgentPage), findsNothing);
        expect(find.byType(ForumPage), findsNothing);
        expect(find.byType(ResearchPage), findsNothing);

        // Navigate to eLearning (Tab 1)
        await tester.tap(find.text('eLearning'));
        await tester.pumpAndSettle();
        expect(find.byType(LearningPage), findsOneWidget);

        // Navigate to Agent (Tab 2)
        await tester.tap(find.text('Agent'));
        await tester.pumpAndSettle();
        expect(find.byType(AgentPage), findsOneWidget);

        // Navigate to 论坛 (Tab 3)
        await tester.tap(find.text('论坛'));
        await tester.pumpAndSettle();
        expect(find.byType(ForumPage), findsOneWidget);

        // Navigate to 科研 (Tab 4)
        await tester.tap(find.text('科研'));
        await tester.pumpAndSettle();
        expect(find.byType(ResearchPage), findsOneWidget);
      },
    );

    testWidgets('External notification navigation event opens TasksScreen', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          home: HomeShell(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Trigger incremental poll that requests opening tasks
      bridge.openTasksOnPoll = true;
      await controller.pollIncrementalEvents();
      await tester.pumpAndSettle();

      // Pushes TasksScreen
      expect(find.byType(TasksScreen), findsOneWidget);
      expect(find.text('任务调度中心'), findsOneWidget);

      // Pop back to shell
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pop();
      await tester.pumpAndSettle();

      final navBar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(navBar.selectedIndex, 0);
    });

    testWidgets(
      'eHall toolbar actions open AccountBalanceScreen and SettingsScreen with PluginsScreen entry',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: HomeShell(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );

        // 1. Tooltip '账号与校园卡'
        await tester.tap(find.byTooltip('账号与校园卡'));
        await tester.pumpAndSettle();

        expect(find.byType(AccountBalanceScreen), findsOneWidget);
        expect(find.text('账号与卡包'), findsOneWidget);
        expect(find.text('student_test_888'), findsOneWidget);

        navigator.pop();
        await tester.pumpAndSettle();

        // 2. Tooltip '设置' -> opens SettingsScreen
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();

        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(find.text('设置'), findsOneWidget);
        expect(find.text('插件管理'), findsOneWidget);

        // 3. Open PluginsScreen from SettingsScreen
        await tester.tap(find.text('插件管理'));
        await tester.pumpAndSettle();

        expect(find.byType(PluginsScreen), findsOneWidget);
        expect(find.text('插件'), findsOneWidget);

        navigator.pop();
        await tester.pumpAndSettle();

        navigator.pop();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Mailing shell under eHall opens sandboxed mailbox view without sending network mails',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: HomeShell(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Scroll to and tap '校园邮箱'
        await tester.scrollUntilVisible(find.text('校园邮箱'), 300);
        await tester.ensureVisible(find.text('校园邮箱'));
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();

        await tester.tap(find.text('校园邮箱'));
        await tester.pumpAndSettle();

        // Verify mailbox shell screen
        expect(find.text('校园邮箱'), findsWidgets);
        expect(find.text('邮箱暂未接入'), findsOneWidget);
        expect(find.text('收件箱'), findsNothing);
      },
    );

    testWidgets(
      'Sports manual booking is independent of plugins, while automation scheduling is gated',
      (tester) async {
        // Initially zero plugins installed: manual booking is fully independent
        bridge.plugins = [];

        await tester.pumpWidget(
          buildTestApp(
            home: HomeShell(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Scroll to '场馆预约' card
        await tester.scrollUntilVisible(find.text('场馆预约'), 200);
        await tester.ensureVisible(find.text('场馆预约'));
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();

        expect(find.text('场馆预约'), findsOneWidget);

        // Tap '预约中心' to open VenuePage
        await tester.tap(find.text('场馆预约'));
        await tester.pumpAndSettle();

        expect(find.byType(VenuePage), findsOneWidget);

        // Gated automation: '创建定时任务' is NOT visible without official.fudan-sports plugin
        expect(find.text('创建定时任务'), findsNothing);

        // Select an available slot in VenuePage
        final today = DateTime.now().toUtc().add(const Duration(hours: 8));
        final tomorrow = today.add(const Duration(days: 1));
        await tester.tap(
          find.text(
            '${tomorrow.month}/${tomorrow.day} ${['周一', '周二', '周三', '周四', '周五', '周六', '周日'][tomorrow.weekday - 1]}',
          ),
        );
        await tester.pumpAndSettle();
        final period = find.byType(CheckboxListTile).first;
        await tester.ensureVisible(period);
        await tester.pumpAndSettle();
        await tester.tap(period);
        await tester.pumpAndSettle();
        final court = find.byType(FilterChip).first;
        await tester.ensureVisible(court);
        await tester.pumpAndSettle();
        await tester.tap(court);
        await tester.pumpAndSettle();

        // Manual reservation button in bottom bar is prominent and enabled
        final reserveBtn = find.text('立即预约');
        expect(reserveBtn, findsOneWidget);
        await tester.tap(reserveBtn);
        await tester.pumpAndSettle();

        // The trusted native sheet owns confirmation; this widget only passes the prepared plan.
        // Verify native host was invoked for venues.reserve with canonical input
        final reserveCall = bridge.invocationLog.firstWhere(
          (c) =>
              c['command'] == HostCommand.campus &&
              c['params']['method'] == 'venues.reservePlan',
        );
        expect(reserveCall, isNotNull);
        expect(find.text('预约成功！'), findsOneWidget);

        // Pop back to eHall
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        navigator.pop();
        await tester.pumpAndSettle();

        // Now install and enable official.fudan-sports plugin: automation is revealed
        bridge.plugins = [
          {
            'id': 'official.fudan-sports',
            'name': '复旦体育场馆抢场',
            'enabled': true,
            'manifest': {
              'id': 'official.fudan-sports',
              'name': '复旦体育场馆抢场',
              'ui': [
                {
                  'id': 'sports_schedule',
                  'type': 'form',
                  'title': '定时任务预约配置',
                  'ui_version': 1,
                  'fields': [],
                  'buttons': [],
                },
              ],
            },
          },
        ];
        await controller.refreshAll();
        await tester.pumpAndSettle();

        // Re-open VenuePage
        await tester.scrollUntilVisible(find.text('场馆预约'), 200);
        await tester.ensureVisible(find.text('场馆预约'));
        await tester.pumpAndSettle();
        await tester.pumpAndSettle();
        await tester.tap(find.text('场馆预约'));
        await tester.pumpAndSettle();

        // Now '创建定时任务' IS visible! (gated scheduling)
        expect(find.text('创建定时任务'), findsOneWidget);

        // Tapping '创建定时任务' opens SchemaScreen
        await tester.ensureVisible(find.text('创建定时任务'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('创建定时任务'));
        await tester.pumpAndSettle();

        expect(find.byType(SchemaScreen), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text('定时任务预约配置'),
          ),
          findsOneWidget,
        );
      },
    );
  });
}
