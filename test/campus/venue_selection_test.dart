import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/campus/venues/venue_models.dart';
import 'package:dansheng_app/ui/campus/venues/venue_page.dart';

import 'venue_test.dart' show MockCampusBridge, createVenueTestApp;

class DelayedCalendarBridge extends MockCampusBridge {
  Completer<String>? delayed;
  final started = Completer<void>();
  @override
  Future<String> invoke(HostCommand command, String payload) {
    final p = jsonDecode(payload) as Map;
    if (command == HostCommand.campus &&
        p['method'] == 'venues.calendar' &&
        delayed != null) {
      final result = delayed!;
      delayed = null;
      started.complete();
      return result.future;
    }
    return super.invoke(command, payload);
  }
}

void main() {
  test('campus matching and campus clock follow DanXi', () {
    expect(const CampusVenue(id: 1, name: '正大体育馆-羽毛球').campus, '邯郸校区');
    expect(const CampusVenue(id: 2, name: '江湾体育馆').campus, '江湾校区');
    const slot = VenueSlot(
      periodId: 1,
      time: '10:00-11:00',
      courtId: 1,
      courtName: 'A',
      available: true,
    );
    expect(
      slot.upcoming(DateTime(2099, 1, 1), DateTime(2099, 1, 1, 9, 59)),
      isTrue,
    );
    expect(
      slot.upcoming(DateTime(2099, 1, 1), DateTime(2099, 1, 1, 10)),
      isFalse,
    );
  });

  testWidgets(
    'three periods, court order and refresh preserve the chosen plan',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = MockCampusBridge();
      bridge.calendarResponse = {
        'slots': [
          for (var period = 1; period <= 4; period++)
            for (var court = 1; court <= 2; court++)
              {
                'period_id': period,
                'time': '${period + 10}:00-${period + 11}:00',
                'court_id': court,
                'court_name': '$court 号场地',
                'available': true,
              },
        ],
      };
      final controller = DanshengController(
        client: DanshengClient(bridge: bridge),
      );
      await controller.initialize();
      await tester.pumpWidget(createVenueTestApp(controller: controller));
      await tester.pumpAndSettle();
      Future<void> tap(String key) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      for (final period in [1, 2, 3]) {
        await tap('period-$period');
      }
      await tap('period-4');
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const ValueKey('period-4')))
            .value,
        isFalse,
      );
      await tap('court-1-2');
      await tap('court-1-1');
      await tap('court-2-1');
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('court-1-2')))
            .selected,
        isTrue,
      );
      await tester.tap(find.text('立即预约'));
      await tester.pumpAndSettle();
      final request =
          bridge.calls.singleWhere(
                (c) => c['params']['method'] == 'venues.reservePlan',
              )['params']['params']
              as Map;
      final plans = request['slots'] as List;
      expect(
        plans,
        hasLength(2),
      ); // An empty selected period must not submit a write.
      expect(plans.first['courts'], [2, 1]);
      expect(plans.last['period_id'], 2);
    },
  );

  testWidgets('an old calendar cannot replace the new account calendar', (
    tester,
  ) async {
    final bridge = DelayedCalendarBridge();
    final old = Completer<String>();
    bridge.delayed = old;
    final controller = DanshengController(
      client: DanshengClient(bridge: bridge),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: VenuePage(
          controller: controller,
          initialDate: DateTime(2099, 1, 1),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 10 && !bridge.started.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(bridge.started.isCompleted, isTrue);
    bridge.activeAccount = 'another-account';
    await controller.switchAccount('another-account');
    await tester.pumpAndSettle();
    old.complete(
      jsonEncode({
        'slots': [
          {'period_id': 999, 'court_id': 1, 'time': 'stale', 'available': true},
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('stale'), findsNothing);
    expect(find.byKey(const ValueKey('period-71')), findsOneWidget);
  });
}
