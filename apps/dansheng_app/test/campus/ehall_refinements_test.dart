import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dansheng_app/ui/campus/ehall/usage_bar_chart.dart';
import 'package:dansheng_app/ui/campus/ehall/power_detail.dart';
import 'package:dansheng_app/ui/campus/venues/venue_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';

import '../ui/test_helpers.dart';
import 'venue_test.dart' show MockCampusBridge;

void main() {
  testWidgets(
    'bar labels stay complete at narrow width and zero usage has zero height',
    (tester) async {
      tester.view.physicalSize = const Size(240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
              body: UsageBarChart(
                period: 'day',
                buckets: const [
                  {
                    'start': '2026-11-01',
                    'end': '2026-11-01',
                    'amount_kwh': '0',
                  },
                  {
                    'start': '2026-11-02',
                    'end': '2026-11-02',
                    'amount_kwh': '12.25',
                  },
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = tester.widget<Text>(
        find.byKey(const ValueKey('usage_axis_0')),
      );
      expect(label.data, '2026\n11/1');
      expect(label.overflow, isNot(TextOverflow.ellipsis));
      expect(
        tester.getSize(find.byKey(const ValueKey('usage_bar_0'))).height,
        0,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('usage_bar_1'))).height,
        greaterThan(0),
      );
      final barTop = tester
          .getRect(find.byKey(const ValueKey('usage_bar_1')))
          .top;
      final valueBottom = tester.getRect(find.text('12.25')).bottom;
      expect(barTop - valueBottom, closeTo(4, 0.1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'electricity granularity is requested from Core and data coverage is visible',
    (tester) async {
      final bridge = MockDanshengBridge();
      final periods = <String>[];
      bridge.campusHandler = (method, params) async {
        if (method == 'fudan.electricity') return {'remaining_kwh': 10};
        if (method == 'fudan.electricity.history') return [];
        if (method == 'fudan.electricity.statistics') {
          periods.add(params['period'] as String);
          return {
            'payload': {
              'period': params['period'],
              'complete': false,
              'record_count': 2,
              'buckets': [
                {
                  'start': '2026-11-01',
                  'end': '2026-11-30',
                  'amount_kwh': '3.25',
                },
              ],
            },
          };
        }
        return null;
      };
      final controller = DanshengController(
        client: DanshengClient(bridge: bridge),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(home: PowerDetailPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      for (final period in ['week', 'month', 'year']) {
        final choice = find.byKey(ValueKey('usage_period_$period'));
        await tester.ensureVisible(choice);
        await tester.pumpAndSettle();
        await tester.tap(choice);
        await tester.pumpAndSettle();
      }
      expect(periods, ['day', 'week', 'month', 'year']);
      expect(find.textContaining('完整性未确认'), findsOneWidget);
    },
  );
  testWidgets(
    'venue calendar action is centered and selected court displays one priority marker',
    (tester) async {
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bridge = MockCampusBridge();
      final controller = DanshengController(
        client: DanshengClient(bridge: bridge),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: VenuePage(
            controller: controller,
            initialVenueId: 900,
            initialDate: DateTime(2099, 1, 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(const Key('venue_date_row'));
      final text = find.descendant(
        of: row,
        matching: find.textContaining('预约日期：'),
      );
      final button = find.byTooltip('选择更多日期');
      expect(
        (tester.getCenter(text).dy - tester.getCenter(button).dy).abs(),
        lessThan(1),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('period-71')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('period-71')));
      await tester.pumpAndSettle();
      final court = find.byKey(const ValueKey('court-71-101'));
      await tester.ensureVisible(court);
      await tester.pumpAndSettle();
      await tester.tap(court);
      await tester.pumpAndSettle();
      final chip = tester.widget<FilterChip>(court);
      expect(chip.selected, isTrue);
      expect(chip.showCheckmark, isFalse);
      expect(chip.avatar, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
}
