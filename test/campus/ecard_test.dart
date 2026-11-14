import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/ehall/life_page.dart';
import 'package:dansheng_app/ui/campus/ehall/ecard_detail.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';

import 'ehall_home_flow_test.dart' show MockHomeFlowBridge;

class CardBridge extends MockHomeFlowBridge {
  final requests = <Map>[], statisticsRequests = <Map>[];
  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final p = jsonDecode(payload) as Map;
    if (command == HostCommand.campus &&
        p['method'] == 'fudan.ecard.statement') {
      final input = p['params'] as Map;
      requests.add(input);
      return jsonEncode({
        'records': [
          for (var i = 1; i <= 2; i++)
            {
              'payload': {
                'at': '${input['from']}T01:20:00Z',
                'location': '合成商户 $i',
                'transaction_type': '消费',
                'amount': {'cents': -1205, 'currency': 'CNY'},
              },
            },
        ],
        'coverage': {'state': 'complete'},
      });
    }
    if (command == HostCommand.campus &&
        p['method'] == 'fudan.ecard.statistics') {
      statisticsRequests.add(p['params'] as Map);
      return jsonEncode({
        'payload': {
          'period': p['params']['period'],
          'from': '2026-11-01',
          'to': '2026-11-30',
          'complete': true,
          'record_count': 3,
          'expense_cents': 305,
          'income_cents': 10000,
          'by_type': [
            {'name': '消费', 'expense_cents': 305, 'count': 2},
          ],
          'by_location': [
            {'name': '合成餐厅', 'expense_cents': 305, 'count': 2},
          ],
        },
      });
    }
    return super.invoke(command, payload);
  }
}

void main() {
  testWidgets(
    'a selected day shows the complete statement without page controls',
    (tester) async {
      final bridge = CardBridge();
      final controller = DanshengController(
        client: DanshengClient(bridge: bridge),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: LifePage(
            service: LifeService.transactions,
            controller: controller,
            initialDate: DateTime(2026, 11, 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('合成商户 1'), findsOneWidget);
      expect(find.text('合成商户 2'), findsOneWidget);
      expect(find.textContaining('09:20'), findsNWidgets(2));
      expect(find.textContaining('-12.05'), findsNWidgets(2));
      expect(find.text('下一页'), findsNothing);
      expect(find.text('上一页'), findsNothing);
      expect(bridge.requests.single, {
        'from': '2026-11-01',
        'to': '2026-11-01',
      });
      await tester.tap(find.byKey(const Key('ecard_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2').last);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(bridge.requests.last, {'from': '2026-11-02', 'to': '2026-11-02'});
      bridge.activeAccount = 'another-account';
      await controller.switchAccount('another-account');
      await tester.pumpAndSettle();
      expect(bridge.requests, hasLength(3));
    },
  );
  testWidgets(
    'statistics opens a new page and requests week month and year from Core',
    (tester) async {
      final bridge = CardBridge();
      final controller = DanshengController(
        client: DanshengClient(bridge: bridge),
      );
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: EcardDetailPage(
            controller: controller,
            initialDate: DateTime(2026, 11, 1),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ecard_statistics_entry')));
      await tester.pumpAndSettle();
      expect(find.byType(EcardStatisticsPage), findsOneWidget);
      expect(find.text('支出合计'), findsOneWidget);
      expect(find.text('¥ 3.05'), findsWidgets);
      expect(find.textContaining('100.00'), findsOneWidget);
      expect(find.text('合成餐厅'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '周'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '年'));
      await tester.pumpAndSettle();
      expect(bridge.statisticsRequests.map((p) => p['period']), [
        'month',
        'week',
        'year',
      ]);
    },
  );
}
