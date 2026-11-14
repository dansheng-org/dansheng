// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:dansheng_app/ui/campus/ehall/room_detail.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDanshengBridge bridge;
  late DanshengClient client;
  late DanshengController controller;

  // Standard SourceBatch test payload
  final testSourceBatch = {
    'records': [
      {
        'id': '501',
        'payload': {
          'room': 'H3101',
          'seats': 80,
          'available': true,
          // 13 periods:
          // 1, 2: free (false)
          // 3, 4: occupied (true)
          // 5: free (false)
          // 6..13: not in list -> MUST be unknown, never false green!
          'busy_units': [false, false, true, true, false],
        },
      },
      {
        'id': '502',
        'payload': {
          'room': 'H3102',
          'seats': 120,
          'available': false,
          'busy_units': [
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
          ],
        },
      },
      {
        'id': '503',
        'payload': {
          'room': 'H3103',
          'seats': 45,
          'available': true,
          'busy_units': [
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
          ],
        },
      },
      {
        'id': '504',
        'payload': {
          'room': 'H3104',
          // No busy_units at all -> all 13 periods must be unknown, never false green!
        },
      },
    ],
  };

  setUp(() async {
    bridge = MockDanshengBridge();
    bridge.accountId = '21307130001';
    client = DanshengClient(bridge: bridge);
    controller = DanshengController(client: client);
    await controller.initialize();
  });

  group('RoomDetailPage initialization and parameters', () {
    testWidgets(
      'defaults to Handan / H3 (第三教学楼) when initialBuilding is null',
      (tester) async {
        final campusCalls = <Map<String, dynamic>>[];
        bridge.campusHandler = (method, params) async {
          campusCalls.add({'method': method, 'params': params});
          if (method == 'fudan.rooms') return testSourceBatch;
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: RoomDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('教室空位'), findsOneWidget);
        expect(find.text('第三教学楼'), findsWidgets);
        expect(find.text('H3101'), findsOneWidget);

        final call = campusCalls.firstWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(call['params']['building'], 'H3');
        expect(call['params']['date'], isNotNull);
      },
    );

    testWidgets(
      'resolves initialBuilding code and switches campus (e.g. F1 in Fenglin)',
      (tester) async {
        final campusCalls = <Map<String, dynamic>>[];
        bridge.campusHandler = (method, params) async {
          campusCalls.add({'method': method, 'params': params});
          if (method == 'fudan.rooms') return testSourceBatch;
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: RoomDetailPage(
              controller: controller,
              initialBuilding: 'F1',
              initialDate: DateTime(2026, 11, 15),
            ),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('枫林一教'), findsWidgets);
        final call = campusCalls.firstWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(call['params']['building'], 'F1');
        expect(call['params']['date'], '2026-11-15');
      },
    );

    testWidgets('resolves Chinese building display name (e.g. 光华楼西 -> HGX)', (
      tester,
    ) async {
      final campusCalls = <Map<String, dynamic>>[];
      bridge.campusHandler = (method, params) async {
        campusCalls.add({'method': method, 'params': params});
        if (method == 'fudan.rooms') return testSourceBatch;
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller, initialBuilding: '光华楼西'),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      final call = campusCalls.firstWhere((c) => c['method'] == 'fudan.rooms');
      expect(call['params']['building'], 'HGX');
    });
  });

  group('Interactive Campus, Building, and Date switching', () {
    testWidgets('switching campus updates building list and triggers fetch', (
      tester,
    ) async {
      final campusCalls = <Map<String, dynamic>>[];
      bridge.campusHandler = (method, params) async {
        campusCalls.add({'method': method, 'params': params});
        if (method == 'fudan.rooms') return testSourceBatch;
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Fenglin campus
      await tester.ensureVisible(find.text('枫林校区'));
      await tester.tap(find.text('枫林校区'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('枫林一教'), findsWidgets);
      expect(find.text('枫林二教'), findsWidgets);

      final lastCall = campusCalls.lastWhere(
        (c) => c['method'] == 'fudan.rooms',
      );
      expect(lastCall['params']['building'], 'F1');
    });

    testWidgets(
      'switching building within campus triggers fetch with new code',
      (tester) async {
        final campusCalls = <Map<String, dynamic>>[];
        bridge.campusHandler = (method, params) async {
          campusCalls.add({'method': method, 'params': params});
          if (method == 'fudan.rooms') return testSourceBatch;
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: RoomDetailPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Tap 第二教学楼 (H2)
        await tester.ensureVisible(find.text('第二教学楼'));
        await tester.tap(find.text('第二教学楼'), warnIfMissed: false);
        await tester.pumpAndSettle();

        var lastCall = campusCalls.lastWhere(
          (c) => c['method'] == 'fudan.rooms',
        );
        expect(lastCall['params']['building'], 'H2');

        // Tap 第四教学楼 (H4)
        await tester.ensureVisible(find.text('第四教学楼'));
        await tester.tap(find.text('第四教学楼'), warnIfMissed: false);
        await tester.pumpAndSettle();

        lastCall = campusCalls.lastWhere((c) => c['method'] == 'fudan.rooms');
        expect(lastCall['params']['building'], 'H4');
      },
    );

    testWidgets('date navigation (next day, prev day) updates query date', (
      tester,
    ) async {
      final campusCalls = <Map<String, dynamic>>[];
      bridge.campusHandler = (method, params) async {
        campusCalls.add({'method': method, 'params': params});
        if (method == 'fudan.rooms') return testSourceBatch;
        return null;
      };

      final fixedDate = DateTime(2026, 11, 8);
      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller, initialDate: fixedDate),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      expect(campusCalls.last['params']['date'], '2026-11-08');

      // Tap next day
      await tester.tap(find.byTooltip('后一天'));
      await tester.pumpAndSettle();
      expect(campusCalls.last['params']['date'], '2026-11-09');

      // Tap prev day
      await tester.tap(find.byTooltip('前一天'));
      await tester.pumpAndSettle();
      expect(campusCalls.last['params']['date'], '2026-11-08');
    });
  });

  group('Classroom list, 13 per-period colored cells, and no false green', () {
    testWidgets(
      'renders 13 numbered cells with correct colors and no false green on unknown',
      (tester) async {
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.rooms') return testSourceBatch;
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: RoomDetailPage(
              controller: controller,
              initialBuilding: 'H3',
              initialDate: DateTime(2026, 11, 8),
            ),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Check room info
        expect(find.text('H3101'), findsOneWidget);
        expect(find.text('80 座'), findsOneWidget);
        expect(find.text('H3102'), findsOneWidget);
        expect(find.text('120 座'), findsOneWidget);
        expect(find.text('H3104'), findsOneWidget);
        expect(find.text('座位数未公布'), findsOneWidget);

        // Verify legend exists
        expect(find.text('空闲'), findsWidgets);
        expect(find.text('占用'), findsWidgets);
        expect(find.text('未知'), findsWidgets);

        // Verify period group labels
        expect(find.text('| 上午'), findsWidgets);
        expect(find.text('| 下午'), findsWidgets);
        expect(find.text('| 晚上'), findsWidgets);

        // Verify accessible semantics and tooltips on cells for H3101:
        // Periods 1, 2: free (空闲) -> green
        // Periods 3, 4: occupied (占用) -> red
        // Period 5: free (空闲) -> green
        // Periods 6..13: missing -> MUST be unknown (未知), NOT free (green)!
        expect(find.byTooltip('第1节: 空闲'), findsWidgets);
        expect(find.byTooltip('第2节: 空闲'), findsWidgets);
        expect(find.byTooltip('第3节: 占用'), findsWidgets);
        expect(find.byTooltip('第4节: 占用'), findsWidgets);
        expect(find.byTooltip('第5节: 空闲'), findsWidgets);
        expect(find.byTooltip('第6节: 未知'), findsWidgets);
        expect(find.byTooltip('第13节: 未知'), findsWidgets);

        // Verify H3104 (no busy_units at all) has summary '时段未公布'
        expect(find.text('H3104'), findsOneWidget);
        expect(find.text('时段未公布'), findsOneWidget);
      },
    );
  });

  group('Optional classroom filter within building', () {
    testWidgets('filtering by classroom name query', (tester) async {
      bridge.campusHandler = (method, params) async {
        if (method == 'fudan.rooms') return testSourceBatch;
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // All 4 rooms visible initially
      expect(find.text('H3101'), findsOneWidget);
      expect(find.text('H3102'), findsOneWidget);
      expect(find.text('H3103'), findsOneWidget);
      expect(find.text('H3104'), findsOneWidget);

      // Enter search query '102'
      await tester.enterText(find.byType(TextField), '102');
      await tester.pumpAndSettle();

      expect(find.text('H3101'), findsNothing);
      expect(find.text('H3102'), findsOneWidget);
      expect(find.text('H3103'), findsNothing);
      expect(find.text('H3104'), findsNothing);

      // Clear search query
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      expect(find.text('H3101'), findsOneWidget);
      expect(find.text('H3102'), findsOneWidget);
    });

    testWidgets('toggle 只看空闲 filters out fully occupied rooms', (tester) async {
      bridge.campusHandler = (method, params) async {
        if (method == 'fudan.rooms') return testSourceBatch;
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Tap 只看空闲
      await tester.tap(find.text('只看空闲'));
      await tester.pumpAndSettle();

      // H3101 has free periods -> visible
      expect(find.text('H3101'), findsOneWidget);
      // H3102 is all occupied -> filtered out
      expect(find.text('H3102'), findsNothing);
      // H3103 is all free -> visible
      expect(find.text('H3103'), findsOneWidget);
      // H3104 has no free periods -> filtered out
      expect(find.text('H3104'), findsNothing);
    });
  });

  group('Auth retry via webvpn and no fake data', () {
    testWidgets('prompts webvpn login retry on AuthenticationRequired error', (
      tester,
    ) async {
      bool throwAuth = true;
      final campusCalls = <Map<String, dynamic>>[];

      bridge.campusHandler = (method, params) async {
        campusCalls.add({'method': method, 'params': params});
        if (method == 'campus.login') {
          throwAuth = false;
          return {'authenticated': true};
        }
        if (method == 'fudan.rooms') {
          if (throwAuth) {
            throw PlatformException(
              code: 'AuthenticationRequired',
              message: 'Session expired',
            );
          }
          return testSourceBatch;
        }
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Error banner with auth retry button shown, NO fake data
      expect(find.text('需要登录校园服务'), findsOneWidget);
      expect(find.text('登录并刷新'), findsOneWidget);
      expect(find.text('H3101'), findsNothing);

      // Tap 登录并刷新
      await tester.tap(find.text('登录并刷新'));
      await tester.pumpAndSettle();

      // Verify campus.login called with webvpn
      final loginCall = campusCalls.firstWhere(
        (c) => c['method'] == 'campus.login',
      );
      expect(loginCall['params']['service'], 'webvpn');

      // Now rooms are loaded from real fudan.rooms
      expect(find.text('H3101'), findsOneWidget);
    });

    testWidgets('falls back to campus.cached on network failure', (
      tester,
    ) async {
      bridge.campusHandler = (method, params) async {
        if (method == 'fudan.rooms') {
          throw PlatformException(code: 'Network', message: 'Timeout');
        }
        if (method == 'campus.cached') {
          return testSourceBatch;
        }
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Cached data displayed with notice
      expect(find.textContaining('当前展示缓存数据'), findsOneWidget);
      expect(find.text('H3101'), findsOneWidget);
    });
  });

  group('Async stale-result handling and account switch', () {
    testWidgets('account switch cancels inflight request and re-queries', (
      tester,
    ) async {
      final campusCalls = <Map<String, dynamic>>[];
      bridge.campusHandler = (method, params) async {
        campusCalls.add({'method': method, 'params': params});
        if (method == 'fudan.rooms') return testSourceBatch;
        return null;
      };

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(campusCalls.length, 1);

      // Switch account
      await controller.switchAccount('21307130002');
      await tester.pumpAndSettle();

      // New query dispatched for switched account
      expect(campusCalls.length, 2);
    });

    testWidgets('unbound account displays login requirement prompt', (
      tester,
    ) async {
      final unauthedBridge = MockDanshengBridge();
      unauthedBridge.accountId = null;
      final unauthedClient = DanshengClient(bridge: unauthedBridge);
      final unauthedController = DanshengController(client: unauthedClient);
      await unauthedController.initialize();

      await tester.pumpWidget(
        buildTestApp(
          home: RoomDetailPage(controller: unauthedController),
          controller: unauthedController,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('未设置账号'), findsOneWidget);
      expect(find.text('H3101'), findsNothing);
    });
  });

  group('Phone and narrow screen responsive rendering', () {
    testWidgets(
      'renders cleanly at 320x640 with 1.8x text scaler without overflow',
      (tester) async {
        final originalOnError = FlutterError.onError;
        bool overflowed = false;
        FlutterError.onError = (FlutterErrorDetails details) {
          if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
            overflowed = true;
            return;
          }
          originalOnError?.call(details);
        };
        addTearDown(() => FlutterError.onError = originalOnError);

        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.resetPhysicalSize());

        controller.setTextScale(1.8);

        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.rooms') return testSourceBatch;
          return null;
        };

        await tester.pumpWidget(
          buildTestApp(
            home: RoomDetailPage(controller: controller),
            controller: controller,
            textScale: 1.8,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('教室空位'), findsOneWidget);
        expect(find.text('H3101'), findsOneWidget);
        expect(overflowed, isFalse);
      },
    );
  });
}
