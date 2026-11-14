import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/ehall/statistics_period_picker.dart';
import 'package:dansheng_app/ui/campus/ehall/usage_bar_chart.dart';
import 'package:dansheng_app/ui/campus/ehall/power_alert_settings.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';

import '../ui/test_helpers.dart';

class AlertBridge extends MockDanshengBridge {
  bool allowNotifications = true;
  int permissionRequests = 0;
  @override
  Future<String> invoke(HostCommand command, String payload) {
    if (command == HostCommand.permissions) {
      return Future.value(
        jsonEncode({'notifications_available': allowNotifications}),
      );
    }
    if (command == HostCommand.requestNotifications) {
      permissionRequests++;
      return Future.value('{}');
    }
    return super.invoke(command, payload);
  }
}

void main() {
  for (final period in ['week', 'month', 'year']) {
    testWidgets('$period statistics selects its own calendar level', (
      tester,
    ) async {
      DateTime? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  chosen = await showStatisticsPeriodPicker(
                    context,
                    period: period,
                    selected: DateTime(2026, 11, 5),
                    today: DateTime(2026, 11, 13),
                  );
                },
                child: const Text('选择周期'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择周期'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('statistics_picker_$period')), findsOneWidget);
      expect(find.byType(CalendarDatePicker), findsNothing);
      if (period == 'year') {
        expect(find.byType(YearPicker), findsOneWidget);
        await tester.tap(find.text('2025'));
        await tester.pumpAndSettle();
        expect(chosen, DateTime(2025));
      } else if (period == 'month') {
        await tester.tap(find.byKey(const ValueKey('statistics_month_5')));
        await tester.pumpAndSettle();
        expect(chosen, DateTime(2026, 5));
      } else {
        await tester.tap(find.byKey(const ValueKey('statistics_week_1')));
        await tester.pumpAndSettle();
        expect(chosen, DateTime(2026, 11, 2));
      }
    });
  }
  testWidgets(
    'usage chart starts at latest date and preserves manual scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final buckets = [
        for (var d = 1; d <= 20; d++)
          {
            'start': '2026-11-${d.toString().padLeft(2, '0')}',
            'amount_kwh': '$d',
          },
      ];
      Widget screen(String period) => MaterialApp(
        home: Scaffold(
          body: UsageBarChart(buckets: buckets, period: period),
        ),
      );
      await tester.pumpWidget(screen('day'));
      await tester.pumpAndSettle();
      final chart = find.byKey(const Key('usage_chart_scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(chart)
          .controller!;
      expect(controller.offset, greaterThan(0));
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, .01),
      );
      await tester.drag(chart, const Offset(250, 0));
      await tester.pumpAndSettle();
      final manual = controller.offset;
      expect(manual, lessThan(controller.position.maxScrollExtent));
      await tester.pumpWidget(screen('day'));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(manual, .01));
      await tester.pumpWidget(screen('week'));
      await tester.pumpAndSettle();
      expect(
        controller.offset,
        closeTo(controller.position.maxScrollExtent, .01),
      );
    },
  );
  testWidgets('reminder saves threshold and can always be disabled', (
    tester,
  ) async {
    final bridge = AlertBridge();
    final writes = <Map>[];
    Map state = {
      'enabled': false,
      'threshold_kwh': 5,
      'background_scheduled': false,
      'notifications_available': true,
    };
    bridge.campusHandler = (method, p) async {
      if (method == 'powerAlert.get') return state;
      if (method == 'powerAlert.set') {
        writes.add(p);
        state = {...state, ...p, 'background_scheduled': p['enabled']};
        return state;
      }
      return null;
    };
    final controller = DanshengController(
      client: DanshengClient(bridge: bridge),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: PowerAlertSettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('power_alert_enabled')));
    await tester.enterText(
      find.byKey(const Key('power_alert_threshold')),
      '3.5',
    );
    await tester.tap(find.byKey(const Key('power_alert_save')));
    await tester.pumpAndSettle();
    expect(writes.single, {'enabled': true, 'threshold_kwh': 3.5});
    expect(find.text('后台检查已安排'), findsOneWidget);
    await tester.tap(find.byKey(const Key('power_alert_enabled')));
    await tester.enterText(
      find.byKey(const Key('power_alert_threshold')),
      'bad',
    );
    await tester.tap(find.byKey(const Key('power_alert_save')));
    await tester.pumpAndSettle();
    expect(writes.last, {'enabled': false, 'threshold_kwh': 3.5});
  });
  testWidgets('notification denial does not enable a reminder', (tester) async {
    final bridge = AlertBridge()..allowNotifications = false;
    var writes = 0;
    bridge.campusHandler = (method, p) async {
      if (method == 'powerAlert.get') {
        return {'enabled': false, 'threshold_kwh': 5};
      }
      if (method == 'powerAlert.set') writes++;
      return null;
    };
    final controller = DanshengController(
      client: DanshengClient(bridge: bridge),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: PowerAlertSettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('power_alert_enabled')));
    await tester.tap(find.byKey(const Key('power_alert_save')));
    await tester.pumpAndSettle();
    expect(bridge.permissionRequests, 1);
    expect(writes, 0);
    expect(find.text('请先允许应用通知'), findsOneWidget);
  });
}
