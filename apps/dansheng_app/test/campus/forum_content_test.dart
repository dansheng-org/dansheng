// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/ui/campus/forum/forum_content.dart';
import 'package:dansheng_app/ui/campus/forum/forum_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preview parses markdown and only substitutes media and formulas', () {
    expect(
      cleanPreviewText('**重点**与[链接](https://example.org)\n\n- 第一项\n- 第二项'),
      '重点与链接\n第一项\n第二项',
    );
    expect(cleanPreviewText(r'行内 $a^2+b^2=c^2$ 与 $$x+y$$'), '行内 [公式] 与 [公式]');
    expect(
      cleanPreviewText('![图](https://example.org/a.png) ![表情](dx_test)'),
      '[图片] [表情]',
    );
    expect(cleanPreviewText('正文 #123 ##456'), '正文');
    expect(cleanPreviewText('#123 ##456'), '#123 ##456');
    expect(cleanPreviewText('<tex>x</tex> <texLine>y</texLine>'), '[公式] [公式]');
  });

  testWidgets(
    'body preserves markdown, line breaks and TeX in a narrow viewport',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 288,
                child: ForumContent(
                  content: r'''# 标题

**加粗**、*斜体*和~~删除线~~。
保留这一行换行。

> 一段讨论引用

- 列表项目

`inline code`

```dart
final answer = 42;
```

行内公式 $a^2+b^2=c^2$。

$$\sum_{i=1}^{n} i = \frac{n(n+1)}{2}$$

<texLine>\int_0^1 x^2 dx</texLine>

<audit>高亮片段</audit>
''',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.byType(Math), findsNWidgets(3));
      expect(find.textContaining('加粗', findRichText: true), findsWidgets);
      expect(find.textContaining('保留这一行换行', findRichText: true), findsWidgets);
      expect(find.text('高亮片段'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'references and links dispatch their own callbacks, code stays literal',
    (tester) async {
      int? hole;
      int? floor;
      Uri? link;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ForumContent(
              content: '#123 和 ##456\n\n[网页](https://example.org)\n\n`#789`',
              onTapHole: (value) => hole = value,
              onTapFloor: (value) => floor = value,
              onTapLink: (value) => link = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('#123'), warnIfMissed: false);
      expect(hole, 123);
      await tester.tap(find.text('##456'), warnIfMissed: false);
      expect(floor, 456);
      await tester.tapOnText(find.textRange.ofSubstring('网页'));
      expect(link.toString(), 'https://example.org');
      expect(hole, isNot(789));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide formulas and failed images fit 320px with enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ForumContent(
                content: r'''正文

$$a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a+a$$

![加载失败](https://example.org/does-not-exist.png)

![贴图](dx_test)

![不可读本地文件](file:///private/example.png)
''',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('[表情：贴图]'), findsOneWidget);
    expect(find.text('[无法显示图片]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
