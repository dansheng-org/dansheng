// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dansheng_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/forum_preview_app.dart';

void main() {
  testWidgets(
    'synthetic forum list and rich detail render without layout errors',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final output = Platform.environment['DANSHENG_FORUM_PREVIEW_OUTPUT'];
      var theme = AppTheme.lightTheme;
      if (output != null && Platform.isWindows) {
        await tester.runAsync(() async {
          final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
          await (FontLoader(
            'preview-cjk',
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        });
        theme = theme.copyWith(
          textTheme: theme.textTheme.apply(fontFamily: 'preview-cjk'),
        );
      }
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: await forumPreviewApp(theme: theme),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        if (output == null) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 2);
          try {
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory(output).create(recursive: true);
            await File('$output/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }

      expect(tester.takeException(), isNull);
      await capture('forum-list');
      await tester.tap(find.textContaining('最近在整理选课和学习资料').first);
      await tester.pumpAndSettle();
      expect(find.text('#123456'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('forum-detail');
      await tester.drag(find.byType(ListView).last, const Offset(0, -540));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture('forum-detail-scrolled');
    },
  );
}
