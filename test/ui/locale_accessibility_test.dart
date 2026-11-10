import 'package:dansheng_app/main.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  testWidgets(
    'first launch exposes Chinese system controls and labeled touch targets without a plugin',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final core = DanshengController(
        client: DanshengClient(bridge: MockDanshengBridge()..accountId = null),
      );
      await core.initialize();
      await tester.pumpWidget(DanshengApp(controller: core));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('校园办事'));
      expect(MaterialLocalizations.of(context).cancelButtonLabel, '取消');
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
      core.dispose();
    },
  );
}
