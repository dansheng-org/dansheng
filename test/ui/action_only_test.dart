import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/schema/schema_models.dart';
import 'package:dansheng_app/ui/schema/schema_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
    'an external page with no fields runs its declared action with only the bound account',
    (tester) async {
      final bridge = MockDanshengBridge();
      Map<String, dynamic>? sent;
      bridge.actionHandlers['read'] = (input) {
        sent = Map.of(input);
        return {'message': '示例结果'};
      };
      final ui = UiDeclarationModel.fromJson({
        'id': 'history',
        'type': 'list',
        'title': '历史',
        'ui_version': 1,
        'buttons': [
          {'label': '查询', 'action': 'read', 'fields': []},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SchemaRenderer(
              pluginId: 'example.optional',
              declaration: ui,
              client: DanshengClient(bridge: bridge),
              activeAccountId: 'a',
            ),
          ),
        ),
      );
      await tester.tap(find.text('查询'));
      await tester.pumpAndSettle();
      expect(sent, {'account_id': 'a'});
    },
  );
}
