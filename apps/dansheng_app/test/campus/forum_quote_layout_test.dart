import 'package:dansheng_app/ui/campus/forum/forum_content.dart';
import 'package:dansheng_app/ui/campus/forum/forum_mention_support.dart';
import 'package:dansheng_app/ui/campus/forum/forum_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, String content) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ForumContent(
          key: const Key('body'),
          content: content,
          selectable: false,
        ),
      ),
    ),
  ),
);

Rect _textRect(WidgetTester tester, String text) => tester.getRect(
  find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(text),
  ),
);

void main() {
  setUp(() {
    ForumFloorCache.instance.putFloor(
      const TeaFloor(
        floorId: 502,
        holeId: 101,
        content: '被引用的楼层内容',
        anonyname: 'Alice',
      ),
    );
  });

  for (final (label, content) in [
    ('on its own line before the reply', '##502\n同感'),
    ('followed on the same line', '##502 同感'),
    ('in the middle of a sentence', '我觉得 ##502 同感'),
    ('of an unknown floor', '##999\n同感'),
    ('of a hole', '#101\n同感'),
  ]) {
    testWidgets('a quote $label takes a full line; the reply starts below', (
      tester,
    ) async {
      await _pump(tester, content);
      final body = tester.getRect(find.byKey(const Key('body')));
      final quote = tester.getRect(find.byType(ForumMentionQuoteWidget));
      expect(quote.width, moreOrLessEquals(body.width, epsilon: 1));
      expect(quote.left, moreOrLessEquals(body.left, epsilon: 1));
      // The words after the quote sit below it, never beside it.
      final reply = find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText().trim() == '同感',
      );
      if (reply.evaluate().isNotEmpty) {
        expect(
          tester.getRect(reply).top,
          greaterThanOrEqualTo(quote.bottom - 1),
        );
      } else {
        expect(_textRect(tester, '同感').bottom, greaterThan(quote.bottom));
      }
    });
  }

  test('saved pictures are recognised by their first bytes', () {
    expect(imageMimeOf([0x89, 0x50, 0x4E, 0x47, 0x0D]), 'image/png');
    expect(imageMimeOf([0xFF, 0xD8, 0xFF, 0xE0]), 'image/jpeg');
    expect(imageMimeOf('GIF89a'.codeUnits), 'image/gif');
    expect(
      imageMimeOf([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]),
      'image/webp',
    );
    expect(imageMimeOf('<html>'.codeUnits), isNull);
    expect(imageMimeOf([]), isNull);
  });
}
