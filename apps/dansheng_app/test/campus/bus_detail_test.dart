// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dansheng_app/ui/campus/ehall/bus_detail.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';

import '../ui/test_helpers.dart';

void main() {
  group('BusDetailPage Tests', () {
    late MockDanshengBridge mockBridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() {
      mockBridge = MockDanshengBridge();
      client = DanshengClient(bridge: mockBridge);
      controller = DanshengController(client: client);
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('1. Sensible initial campus and real schema parsing', (
      tester,
    ) async {
      mockBridge.campusHandler = (method, params) async {
        if (method == 'fudan.bus') {
          return {
            'records': [
              {
                'id': 'bus-1',
                'from': '邯郸校区',
                'to': '江湾校区',
                'starts_at': '07:30',
                'ends_at': '08:10',
                'direction': 'forward',
                'holiday': false,
              },
              {
                'id': 'bus-2',
                'from': '邯郸校区',
                'to': '枫林校区',
                'starts_at': '08:00',
                'ends_at': '08:50',
                'direction': 'forward',
                'holiday': false,
              },
            ].map((row) => {'external_id': row['id'], 'payload': row}).toList(),
          };
        }
        return {};
      };

      // Set initial reference date to a weekday at 07:00
      final mondayMorning = DateTime(2026, 11, 9, 7, 0); // Monday

      await tester.pumpWidget(
        buildTestApp(
          home: BusDetailPage(
            controller: controller,
            initialDate: mondayMorning,
          ),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Title should be present
      expect(find.text('校车班次'), findsOneWidget);

      // Initial campuses default to Handan -> Jiangwan
      expect(find.text('邯郸校区'), findsWidgets);
      expect(find.text('江湾校区'), findsWidgets);

      // Only bus-1 matches Handan -> Jiangwan
      expect(find.text('07:30'), findsOneWidget);
      expect(find.text('08:10'), findsOneWidget);
      // bus-2 (to Fenglin) should be filtered out
      expect(find.text('08:50'), findsNothing);
    });

    testWidgets(
      '2. Workday and holiday switch calls fudan.bus with holiday param',
      (tester) async {
        final calls = <Map<String, dynamic>>[];
        mockBridge.campusHandler = (method, params) async {
          calls.add({'method': method, 'params': params});
          final holiday = params['holiday'] == true;
          return [
            {
              'id': 'bus-w',
              'from': '邯郸校区',
              'to': '江湾校区',
              'starts_at': holiday ? '10:00' : '07:30',
              'ends_at': holiday ? '10:40' : '08:10',
              'direction': 'forward',
              'holiday': holiday,
            },
          ];
        };

        // Monday weekday reference
        final monday = DateTime(2026, 11, 9, 7, 0);

        await tester.pumpWidget(
          buildTestApp(
            home: BusDetailPage(controller: controller, initialDate: monday),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        expect(calls.last['params']['holiday'], isFalse);
        expect(find.text('07:30'), findsOneWidget);

        // Toggle to holiday schedule
        await tester.tap(find.text('节假日'));
        await tester.pumpAndSettle();

        expect(calls.last['params']['holiday'], isTrue);
        expect(find.text('10:00'), findsOneWidget);

        // Toggle back to workday: should use cached workday list without new call
        final countBefore = calls.length;
        await tester.tap(find.text('工作日'));
        await tester.pumpAndSettle();

        expect(find.text('07:30'), findsOneWidget);
        expect(calls.length, countBefore);
      },
    );

    testWidgets(
      '3. Outgoing vs bidirectional filter with source direction normalized',
      (tester) async {
        mockBridge.campusHandler = (method, params) async {
          return [
            // Forward bus: Handan -> Jiangwan ONLY
            {
              'id': 'forward-bus',
              'from': '邯郸校区',
              'to': '江湾校区',
              'starts_at': '08:00',
              'ends_at': '08:40',
              'direction': 'forward',
            },
            // Bidirectional bus: between Handan and Jiangwan
            {
              'id': 'dual-bus',
              'from': '邯郸校区',
              'to': '江湾校区',
              'starts_at': '09:00',
              'ends_at': '09:40',
              'direction': 'both',
            },
            // Backward bus entered as Handan -> Jiangwan, meaning actual route is Jiangwan -> Handan
            {
              'id': 'backward-bus',
              'from': '邯郸校区',
              'to': '江湾校区',
              'starts_at': '10:00',
              'ends_at': '10:40',
              'direction': 'backward',
            },
          ];
        };

        final refDate = DateTime(2026, 11, 9, 6, 0);

        await tester.pumpWidget(
          buildTestApp(
            home: BusDetailPage(controller: controller, initialDate: refDate),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Handan -> Jiangwan query:
        // forward-bus matches (08:00)
        // dual-bus matches (09:00)
        // backward-bus is actually Jiangwan -> Handan, so should NOT match
        expect(find.text('08:00'), findsOneWidget);
        expect(find.text('09:00'), findsOneWidget);
        expect(find.text('10:00'), findsNothing);

        // Tap swap button to reverse query: Jiangwan -> Handan
        await tester.tap(find.byTooltip('互换起点和终点'));
        await tester.pumpAndSettle();

        // In Jiangwan -> Handan:
        // forward-bus does NOT match
        // dual-bus matches in reverse (normalized)
        // backward-bus matches (normalized to Jiangwan -> Handan)
        expect(find.text('08:00'), findsNothing);
        expect(
          find.text('09:40'),
          findsOneWidget,
        ); // dual-bus departure in reverse
        expect(
          find.text('10:40'),
          findsOneWidget,
        ); // backward-bus departure in reverse
      },
    );

    testWidgets(
      '4. Meaningful empty states for identical campus and no results',
      (tester) async {
        mockBridge.campusHandler = (method, params) async {
          return [];
        };

        final refDate = DateTime(2026, 11, 9, 8, 0);

        await tester.pumpWidget(
          buildTestApp(
            home: BusDetailPage(controller: controller, initialDate: refDate),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // No results from empty API response
        expect(find.text('暂无相关校车班次'), findsOneWidget);

        // Set destination to same as origin (Handan)
        await tester.tap(find.byKey(const Key('bus_dest_dropdown')));
        await tester.pumpAndSettle();

        // In the dropdown menu, select '邯郸校区'
        await tester.tap(find.text('邯郸校区').last);
        await tester.pumpAndSettle();

        expect(find.text('起点与终点相同，请重新选择校区'), findsOneWidget);
      },
    );

    testWidgets('5. Show all toggle displays departed buses', (tester) async {
      mockBridge.campusHandler = (method, params) async {
        return [
          {
            'id': 'bus-early',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '07:00',
            'ends_at': '07:40',
            'direction': 'forward',
          },
          {
            'id': 'bus-late',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '09:00',
            'ends_at': '09:40',
            'direction': 'forward',
          },
        ];
      };

      // Reference time is 08:00: bus-early has already departed
      final refDate = DateTime(2026, 11, 9, 8, 0);

      await tester.pumpWidget(
        buildTestApp(
          home: BusDetailPage(controller: controller, initialDate: refDate),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // By default upcoming only: 07:00 hidden, 09:00 shown
      expect(find.text('07:00'), findsNothing);
      expect(find.text('09:00'), findsOneWidget);
      expect(find.textContaining('仅显示 08:00 以后的校车班次'), findsOneWidget);

      // Tap info card to show all
      await tester.tap(find.textContaining('仅显示 08:00 以后的校车班次'));
      await tester.pumpAndSettle();

      // Now both buses appear
      expect(find.text('已显示全部校车班次'), findsOneWidget);
      expect(find.text('07:00'), findsOneWidget);
      expect(find.text('09:00'), findsOneWidget);

      // Tap again to restore upcoming filter
      await tester.tap(find.text('已显示全部校车班次'));
      await tester.pumpAndSettle();
      expect(find.text('07:00'), findsNothing);
      expect(find.text('09:00'), findsOneWidget);
    });

    testWidgets(
      '6. Stale request handling prevents out-of-order race conditions',
      (tester) async {
        final completer1 = Completer<List<dynamic>>();
        final completer2 = Completer<List<dynamic>>();

        int callIndex = 0;
        mockBridge.campusHandler = (method, params) async {
          callIndex++;
          if (callIndex == 1) {
            return completer1.future;
          } else {
            return completer2.future;
          }
        };

        final refDate = DateTime(2026, 11, 9, 6, 0);

        await tester.pumpWidget(
          buildTestApp(
            home: BusDetailPage(controller: controller, initialDate: refDate),
            controller: controller,
          ),
        );
        await tester.pump(); // Request 1 is in-flight

        // Switch to holiday before request 1 finishes: triggers request 2
        await tester.tap(find.text('节假日'));
        await tester.pump(); // Request 2 is in-flight

        // Complete request 2 first (holiday)
        completer2.complete([
          {
            'id': 'bus-holiday',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '11:00',
            'ends_at': '11:40',
            'direction': 'forward',
            'holiday': true,
          },
        ]);
        await tester.pumpAndSettle();
        expect(find.text('11:00'), findsOneWidget);

        // Now complete older request 1 with stale data
        completer1.complete([
          {
            'id': 'bus-stale-weekday',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '06:30',
            'ends_at': '07:10',
            'direction': 'forward',
            'holiday': false,
          },
        ]);
        await tester.pumpAndSettle();

        // Older stale request must NOT overwrite current holiday display
        expect(find.text('11:00'), findsOneWidget);
        expect(find.text('06:30'), findsNothing);
      },
    );

    testWidgets('7. Authentication error triggers login and reload', (
      tester,
    ) async {
      bool loggedIn = false;
      final apiCalls = <String>[];

      mockBridge.campusHandler = (method, params) async {
        apiCalls.add(method);
        if (method == 'fudan.bus') {
          if (!loggedIn) {
            throw 'AuthenticationRequired';
          }
          return [
            {
              'id': 'bus-auth-ok',
              'from': '邯郸校区',
              'to': '江湾校区',
              'starts_at': '08:30',
              'ends_at': '09:10',
              'direction': 'forward',
            },
          ];
        }
        if (method == 'campus.cached') {
          return null;
        }
        if (method == 'campus.login') {
          loggedIn = true;
          return {'success': true};
        }
        return {};
      };

      final refDate = DateTime(2026, 11, 9, 6, 0);

      await tester.pumpWidget(
        buildTestApp(
          home: BusDetailPage(controller: controller, initialDate: refDate),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('需要登录校园服务'), findsOneWidget);
      expect(find.text('登录并刷新'), findsOneWidget);

      // Tap login and refresh
      await tester.tap(find.text('登录并刷新'));
      await tester.pumpAndSettle();

      expect(apiCalls, contains('campus.login'));
      expect(find.text('08:30'), findsOneWidget);
    });

    testWidgets('8. Selectable all campus option allows broad overview', (
      tester,
    ) async {
      mockBridge.campusHandler = (method, params) async {
        return [
          {
            'id': 'bus-1',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '08:00',
            'ends_at': '08:40',
            'direction': 'forward',
          },
          {
            'id': 'bus-2',
            'from': '邯郸校区',
            'to': '枫林校区',
            'starts_at': '08:30',
            'ends_at': '09:20',
            'direction': 'forward',
          },
        ];
      };

      final refDate = DateTime(2026, 11, 9, 6, 0);

      await tester.pumpWidget(
        buildTestApp(
          home: BusDetailPage(controller: controller, initialDate: refDate),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Initially Handan -> Jiangwan: only bus-1
      expect(find.text('08:00'), findsOneWidget);
      expect(find.text('08:30'), findsNothing);

      // Change destination to '全部校区'
      await tester.tap(find.byKey(const Key('bus_dest_dropdown')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('全部校区').last);
      await tester.pumpAndSettle();

      // Now both buses from Handan to any destination are shown
      expect(find.text('08:00'), findsOneWidget);
      expect(find.text('08:30'), findsOneWidget);
    });

    test('9. Each direction maps to a Material icon', () {
      expect(BusDirection.FORWARD.icon, Icons.arrow_forward_rounded);
      expect(BusDirection.NONE.icon, Icons.arrow_forward_rounded);
      expect(BusDirection.BACKWARD.icon, Icons.arrow_back_rounded);
      expect(BusDirection.DUAL.icon, Icons.swap_horiz_rounded);
    });

    testWidgets('10. Rows draw direction as an icon, never an arrow character', (
      tester,
    ) async {
      mockBridge.campusHandler = (method, params) async {
        return [
          {
            'id': 'dual-bus',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '08:00',
            'ends_at': '08:40',
            'direction': 'both',
          },
          {
            'id': 'forward-bus',
            'from': '邯郸校区',
            'to': '江湾校区',
            'starts_at': '09:00',
            'ends_at': '09:40',
            'direction': 'forward',
          },
        ];
      };
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        buildTestApp(
          home: BusDetailPage(
            controller: controller,
            initialDate: DateTime(2026, 11, 9, 6, 0),
          ),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      Finder directionIcon(IconData icon, String label) =>
          find.byWidgetPredicate(
            (w) => w is Icon && w.icon == icon && w.semanticLabel == label,
          );

      final dual = directionIcon(Icons.swap_horiz_rounded, '双向');
      expect(dual, findsOneWidget);
      // The swap button draws the same glyph, so the page reads as one family.
      expect(find.byIcon(Icons.swap_horiz_rounded), findsNWidgets(2));
      expect(directionIcon(Icons.arrow_forward_rounded, '单向'), findsOneWidget);

      final icon = tester.widget<Icon>(dual);
      expect(icon.size, 22);
      expect(icon.color, Theme.of(tester.element(dual)).colorScheme.outline);

      // The glyph communicates direction without a second caption
      expect(find.text('双向'), findsNothing);

      // Icon and caption must not make screen readers say it twice
      final card = find.ancestor(of: dual, matching: find.byType(Card));
      final spoken = tester.getSemantics(card).label;
      expect('双向'.allMatches(spoken), hasLength(1));

      for (final arrow in ['↔', '→', '←']) {
        expect(find.textContaining(arrow), findsNothing);
      }
      semantics.dispose();
    });
  });
}
