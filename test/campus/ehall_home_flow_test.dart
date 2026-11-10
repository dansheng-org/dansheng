// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/campus/ehall/ehall_page.dart';
import 'package:dansheng_app/ui/campus/ehall/life_page.dart';
import 'package:dansheng_app/ui/screens/account_balance_screen.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';

class MockHomeFlowBridge implements DanshengBridge {
  String? activeAccount = '21307130001';
  List<Map<String, dynamic>> plugins = [];
  final List<Map<String, dynamic>> campusCalls = [];
  Map<String, dynamic> balanceData = {
    'balance': '238.50',
    'holder_name': '复旦同学',
    'currency': 'CNY',
    'updated_at': '2026-11-08T08:00:00Z',
  };

  String? throwOnMethod;
  String throwCode = 'AuthenticationRequired';
  int callDelayMs = 0;

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final Map<String, dynamic> params = payload.isNotEmpty
        ? (jsonDecode(payload) as Map<String, dynamic>)
        : <String, dynamic>{};

    switch (command) {
      case HostCommand.info:
        return jsonEncode({'version': '0.1.0'});
      case HostCommand.plugins:
        return jsonEncode(plugins);
      case HostCommand.account:
        return jsonEncode({'account_id': activeAccount});
      case HostCommand.setAccount:
        activeAccount = params['account_id']?.toString();
        return jsonEncode({'account_id': activeAccount});
      case HostCommand.jobs:
        return jsonEncode([]);
      case HostCommand.permissions:
        return jsonEncode({
          'exact_available': true,
          'notifications_available': true,
        });
      case HostCommand.balance:
        return jsonEncode(balanceData);
      case HostCommand.campus:
        final method = params['method']?.toString() ?? '';
        final methodParams = params['params'] as Map<String, dynamic>? ?? {};
        campusCalls.add({'method': method, 'params': methodParams});

        if (callDelayMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: callDelayMs));
        }

        if (throwOnMethod != null && method == throwOnMethod) {
          throw PlatformException(code: throwCode, message: throwCode);
        }

        switch (method) {
          case 'campus.cached':
            final cachedMethod = methodParams['method'];
            if (cachedMethod == 'fudan.electricity') {
              return jsonEncode({
                'id': 'electricity:ROOM-201',
                'payload': {
                  'room_id': 'ROOM-201',
                  'campus': '邯郸校区',
                  'building': '东安一号楼',
                  'room': '302室',
                  'remaining_kwh': 45.2,
                  'used_kwh': 120.5,
                },
              });
            }
            if (cachedMethod == 'fudan.rooms') {
              return jsonEncode([
                {
                  'id': '501',
                  'payload': {
                    'room': 'H3101',
                    'seats': 80,
                    'available': true,
                    'busy_units': [false, false, true, true, false],
                  },
                },
              ]);
            }
            return jsonEncode(null);

          case 'fudan.electricity':
            return jsonEncode({
              'id': 'electricity:ROOM-201',
              'payload': {
                'room_id': 'ROOM-201',
                'campus': '邯郸校区',
                'building': '东安一号楼',
                'room': '302室',
                'remaining_kwh': 42.0,
                'used_kwh': 125.0,
              },
            });

          case 'fudan.library.occupancy':
            return jsonEncode({
              'records': [
                {'campus': '邯郸文科图书馆', 'inside': 142, 'capacity': 500},
                {'campus': '李兆基图书馆', 'inside': 328, 'capacity': 800},
              ].map((row) => {'payload': row}).toList(),
            });

          case 'fudan.dining.occupancy':
            return jsonEncode({
              'records': [
                {'name': '光华餐厅一楼', 'current': 210, 'capacity': 600},
                {'name': '旦苑餐厅二楼', 'current': 380, 'capacity': 800},
              ].map((row) => {'payload': row}).toList(),
            });

          case 'fudan.rooms':
            return jsonEncode([
              {
                'id': '501',
                'room': 'H3101',
                'seats': 80,
                'available': true,
                'busy_units': [false, false, true, true, false],
              },
            ]);

          case 'fudan.bus':
            return jsonEncode([
              {
                'id': 'bus-1',
                'from': '邯郸校区',
                'to': '江湾校区',
                'starts_at': '07:30',
                'ends_at': '08:10',
                'direction': 'both',
              },
            ]);

          case 'fudan.notices':
            return jsonEncode([
              {'title': '关于秋季学期选课安排的通知', 'published_on': '2026-11-01'},
            ]);

          case 'fudan.ecard.transactions':
            return jsonEncode([
              {
                'location': '旦苑第一餐厅',
                'transaction_type': '餐饮消费',
                'at': '2026-11-08 12:15',
                'amount': {'cents': 1850, 'currency': 'CNY'},
              },
            ]);

          case 'venues.venues':
            return jsonEncode([
              {'id': 900, 'name': '正大体育馆羽毛球场'},
            ]);

          case 'venues.calendar':
            return jsonEncode({
              'slots': [
                {
                  'period_id': 71,
                  'time': '10:00-11:00',
                  'court_id': 101,
                  'court_name': '1号场地',
                  'available': true,
                },
              ],
            });

          default:
            return jsonEncode({'result': 'ok'});
        }
      default:
        return jsonEncode({'result': 'ok'});
    }
  }
}

Widget buildTestApp({required Widget home}) {
  return MaterialApp(
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    home: home,
  );
}

void main() {
  group('eHall Home Interaction & Metric Flows', () {
    late MockHomeFlowBridge mockBridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() async {
      mockBridge = MockHomeFlowBridge();
      client = DanshengClient(bridge: mockBridge);
      controller = DanshengController(client: client);
      await controller.initialize();
      await controller.refreshBalance();
    });

    testWidgets(
      '1. Tapping top balance card opens LifePage.transactions directly; refresh icon reads balance',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Standalone 校园卡明细 entry must not appear in the service list
        expect(find.widgetWithText(ListTile, '校园卡明细'), findsNothing);

        // Tap the refresh icon: reads balance without navigating
        mockBridge.balanceData = {
          'balance': '366.80',
          'holder_name': '复旦同学',
          'currency': 'CNY',
          'updated_at': '2026-11-08T09:00:00Z',
        };
        await tester.tap(find.byTooltip('刷新余额'));
        await tester.pumpAndSettle();

        expect(find.text('¥ 366.80'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);
        expect(find.byType(AccountBalanceScreen), findsNothing);

        // Tap the card body: navigates directly to LifePage.transactions without trip to account settings
        await tester.tap(find.text('¥ 366.80'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('校园卡明细'), findsOneWidget);
        expect(find.byType(AccountBalanceScreen), findsNothing);

        // Verifies transactions endpoint was queried
        final calls = mockBridge.campusCalls.map((c) => c['method']).toList();
        expect(calls, contains('fudan.ecard.transactions'));
      },
    );

    testWidgets(
      '2. Dorm power: cached on open, first tap fetches live metric, second tap opens LifePage.power',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Zero hidden live network calls on open
        var livePowerCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'fudan.electricity')
            .toList();
        expect(livePowerCalls, isEmpty);

        // Cached value is shown
        expect(find.text('45.2 kWh'), findsOneWidget);

        // First tap: cache is not treated as successful user tap; triggers live fetch
        await tester.tap(find.text('寝室电量'));
        await tester.pumpAndSettle();

        // Verified live network call happened
        livePowerCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'fudan.electricity')
            .toList();
        expect(livePowerCalls, hasLength(1));

        // Real live metric updated on card
        expect(find.text('42.0 kWh'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);

        // Second tap: opens detail LifePage.power
        await tester.tap(find.text('寝室电量'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
        expect(find.byType(PowerDetailPage), findsOneWidget);
        expect(find.text('42.0'), findsOneWidget);
        expect(find.text('kWh'), findsWidgets);
        expect(find.textContaining('剩余：42.0 kWh'), findsOneWidget);
      },
    );

    testWidgets(
      '3. Library: first tap fetches live metric and shows real numbers, second tap opens LifePage.library',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Initial state: no network call, placeholder subtitle
        var libCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'fudan.library.occupancy')
            .toList();
        expect(libCalls, isEmpty);
        expect(find.text('各馆舍在馆人数与实时负载'), findsOneWidget);

        // First tap: fetches live occupancy
        await tester.scrollUntilVisible(find.text('图书馆客流'), 200);
        await tester.tap(find.text('图书馆客流'));
        await tester.pumpAndSettle();

        libCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'fudan.library.occupancy')
            .toList();
        expect(libCalls, hasLength(1));

        // Inline metric displays real numbers without faking
        expect(find.textContaining('142人'), findsOneWidget);
        expect(find.textContaining('328人'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);

        // Second tap: opens LifePage.library
        await tester.tap(find.text('图书馆客流'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('当前在馆 142 人 / 容量 500'), findsOneWidget);
      },
    );

    testWidgets(
      '4. Dining: first tap fetches live metric and shows real numbers, second tap opens LifePage.dining',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        var diningCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'fudan.dining.occupancy')
            .toList();
        expect(diningCalls, isEmpty);

        // First tap: fetches live dining occupancy
        await tester.scrollUntilVisible(find.text('食堂实时客流'), 200);
        await tester.tap(find.text('食堂实时客流'));
        await tester.pumpAndSettle();

        diningCalls = mockBridge.campusCalls
            .where((c) => c['method'] == 'fudan.dining.occupancy')
            .toList();
        expect(diningCalls, hasLength(1));

        // Inline metric displays real numbers
        expect(find.textContaining('210人'), findsOneWidget);
        expect(find.textContaining('380人'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);

        // Second tap: opens LifePage.dining
        await tester.tap(find.text('食堂实时客流'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('当前就餐 210 人 / 餐厅容量 600'), findsOneWidget);
      },
    );

    testWidgets(
      '5. Direct detail navigation for selectors (rooms), route tools (bus), and announcements',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // 1. Bus: route tool navigates directly on single tap
        await tester.scrollUntilVisible(find.text('校车班次时刻'), 200);
        await tester.tap(find.text('校车班次时刻'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('校车班次'), findsOneWidget);

        // Pop back to home
        Navigator.of(tester.element(find.byType(LifePage))).pop();
        await tester.pumpAndSettle();

        // 2. Announcements: navigates directly on single tap
        await tester.scrollUntilVisible(find.text('教务公告'), 200);
        await tester.tap(find.text('教务公告'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('教务公告'), findsWidgets);
      },
    );

    testWidgets('6. No duplicate in-flight reads when user taps rapidly', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      mockBridge.callDelayMs = 200;

      await tester.pumpWidget(
        buildTestApp(home: EHallPage(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('图书馆客流'), 200);

      // Tap once
      await tester.tap(find.text('图书馆客流'));
      await tester.pump(const Duration(milliseconds: 50));

      // Rapid tap while read is still in-flight
      await tester.tap(find.text('图书馆客流'));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.pumpAndSettle();

      final libCalls = mockBridge.campusCalls
          .where((c) => c['method'] == 'fudan.library.occupancy')
          .toList();
      expect(
        libCalls,
        hasLength(1),
        reason: 'Duplicate in-flight read must be suppressed',
      );
    });

    testWidgets(
      '7. Retries failed reads and does not advance to detail until successful',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.throwOnMethod = 'fudan.dining.occupancy';
        mockBridge.throwCode = 'NetworkTimeout';

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // First tap fails due to network error
        await tester.scrollUntilVisible(find.text('食堂实时客流'), 200);
        await tester.tap(find.text('食堂实时客流'));
        await tester.pumpAndSettle();

        expect(find.textContaining('点击重试'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);

        // Recover bridge
        mockBridge.throwOnMethod = null;

        // Second tap retries the failed read
        await tester.tap(find.text('食堂实时客流'));
        await tester.pumpAndSettle();

        // Successful read now displays real metric
        expect(find.textContaining('210人'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);

        // Third tap now opens LifePage detail
        await tester.tap(find.text('食堂实时客流'));
        await tester.pumpAndSettle();

        expect(find.byType(LifePage), findsOneWidget);
      },
    );

    testWidgets(
      '8. Explicit 2FA error dispatches directly to LifePage.dining',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.throwOnMethod = 'fudan.dining.occupancy';
        mockBridge.throwCode = 'TwoFactorRequired';

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('食堂实时客流'), 200);
        await tester.tap(find.text('食堂实时客流'));
        await tester.pumpAndSettle();

        // Dispatched directly to LifePage.dining for 2FA handling
        expect(find.byType(LifePage), findsOneWidget);
        expect(find.text('食堂客流'), findsOneWidget);
      },
    );

    testWidgets(
      '9. General authentication required explicitly navigates to account screen',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        mockBridge.throwOnMethod = 'fudan.library.occupancy';
        mockBridge.throwCode = 'AuthenticationRequired';

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        await tester.scrollUntilVisible(find.text('图书馆客流'), 200);
        await tester.tap(find.text('图书馆客流'));
        await tester.pumpAndSettle();

        // Explicit navigation to account settings for login recovery
        expect(find.byType(AccountBalanceScreen), findsOneWidget);
      },
    );

    testWidgets(
      '10. Per-account state drops in-flight reads and isolates fetched status on account switch',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          buildTestApp(home: EHallPage(controller: controller)),
        );
        await tester.pumpAndSettle();

        // Fetch dorm power on Account 1
        await tester.tap(find.text('寝室电量'));
        await tester.pumpAndSettle();
        expect(find.text('42.0 kWh'), findsOneWidget);

        // Switch to Account 2
        await controller.switchAccount('21307130099');
        await tester.pumpAndSettle();

        // Account 2 has fresh pending state, live metric not fetched yet
        expect(find.text('42.0 kWh'), findsNothing);
        expect(find.text('45.2 kWh'), findsOneWidget); // Offline cache

        // First tap on Account 2 triggers live fetch for Account 2, does NOT navigate
        await tester.tap(find.text('寝室电量'));
        await tester.pumpAndSettle();

        expect(find.text('42.0 kWh'), findsOneWidget);
        expect(find.byType(LifePage), findsNothing);
      },
    );
  });
}
