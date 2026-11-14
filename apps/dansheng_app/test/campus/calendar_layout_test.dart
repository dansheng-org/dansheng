import 'package:dansheng_app/ui/campus/learning/learning_controller.dart';
import 'package:dansheng_app/ui/campus/learning/widgets/calendar_header.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/test_helpers.dart';

void main() {
  testWidgets(
    'the calendar fits a narrow phone at enlarged system type in week and month modes',
    (tester) async {
      final owner = DanshengController(
        client: DanshengClient(bridge: MockDanshengBridge()),
      );
      final calendar = LearningController(
        appController: owner,
        now: () => DateTime.utc(2026, 11, 8, 2),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: ListenableBuilder(
                    listenable: calendar,
                    builder: (_, _) => CalendarHeader(controller: calendar),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('月'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('下一月'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      calendar.dispose();
      owner.dispose();
    },
  );
}
