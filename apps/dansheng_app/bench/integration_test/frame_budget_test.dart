import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/main.dart' show DanshengApp;
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// This separately installed benchmark renders the production catalog against fixed local
// data. It never changes the installed user's account or performs network I/O.
class _Data implements DanshengBridge {
  final rooms = List.generate(
    80,
    (i) => {
      'payload': {
        'room': '第三教学楼 ${100 + i}',
        'seats': 48,
        'busy_units': [true, false, false, true],
      },
    },
  );
  @override
  Future<String> invoke(HostCommand command, String payload) async =>
      jsonEncode(switch (command) {
        HostCommand.plugins => [],
        HostCommand.campus =>
          jsonDecode(payload)['method'] == 'fudan.rooms'
              ? {'records': rooms}
              : null,
        HostCommand.account => {'account_id': 'benchmark'},
        HostCommand.jobs => [],
        HostCommand.events => {'events': [], 'cursor': 0},
        _ => <String, dynamic>{},
      });
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('80 rooms, scrolling, routing and input at 60 Hz', (
    tester,
  ) async {
    expect(kProfileMode, isTrue, reason: 'Use --profile on an ARM64 phone.');
    final hz = ui.PlatformDispatcher.instance.displays.first.refreshRate;
    expect(
      hz,
      inInclusiveRange(59.0, 61.0),
      reason: 'Set the device to 60 Hz first.',
    );
    final controller = DanshengController(
      client: DanshengClient(bridge: _Data()),
    );
    await controller.initialize();
    await tester.pumpWidget(DanshengApp(controller: controller));
    await tester.pumpAndSettle();
    final reports = <Map<String, Object>>[];
    for (var i = 0; i < 3; i++) {
      final samples = <ui.FrameTiming>[];
      void collect(List<ui.FrameTiming> batch) => samples.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(collect);
      try {
        await tester.tap(find.text('教室空位').first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '第三教学楼');
        await tester.tap(find.text('查询教室空位'));
        await tester.pumpAndSettle();
        final list = find.byType(ListView).last;
        await tester.fling(list, const Offset(0, -1150), 2200);
        await tester.pumpAndSettle();
        await tester.fling(list, const Offset(0, 1850), 3200);
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1100)),
        );
      } finally {
        SchedulerBinding.instance.removeTimingsCallback(collect);
      }
      expect(
        samples.length,
        greaterThanOrEqualTo(20),
        reason: 'No meaningful frame sample.',
      );
      double p95(List<int> xs) {
        xs.sort();
        return xs[(xs.length * .95).ceil() - 1] / 1000;
      }

      final builds = samples
          .map((f) => f.buildDuration.inMicroseconds)
          .toList();
      final rasters = samples
          .map((f) => f.rasterDuration.inMicroseconds)
          .toList();
      reports.add({
        'round': i + 1,
        'samples': samples.length,
        'refresh_hz': hz,
        'build_p95_ms': p95(builds),
        'raster_p95_ms': p95(rasters),
        'over_budget_fraction':
            samples
                .where(
                  (f) =>
                      f.buildDuration.inMicroseconds > 16700 ||
                      f.rasterDuration.inMicroseconds > 16700,
                )
                .length /
            samples.length,
      });
    }
    binding.reportData = {
      'dataset': '80 synthetic classrooms',
      'frames': reports,
    };
    for (final r in reports) {
      expect(r['build_p95_ms'] as double, lessThanOrEqualTo(16.7));
      expect(r['raster_p95_ms'] as double, lessThanOrEqualTo(16.7));
    }
  });
}
