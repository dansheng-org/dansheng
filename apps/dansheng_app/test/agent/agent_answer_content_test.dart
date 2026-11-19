import 'package:dansheng_app/ui/campus/agent/agent_answer_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders Markdown and both forms of inline and display math', (
    tester,
  ) async {
    await _pump(tester, r'''
## 电路分析

The **gain** is $A_v$ and the input is \(v_i\).

$$
\frac{v_o}{v_i}
$$

\[\omega = 2\pi f\]
''');

    expect(find.text('电路分析'), findsOneWidget);
    final paragraph = tester.widget<Text>(find.textContaining('gain'));
    final spans = (paragraph.textSpan! as TextSpan).children!;
    expect(
      spans.whereType<TextSpan>().any(
        (span) =>
            span.text == 'gain' && span.style?.fontWeight == FontWeight.bold,
      ),
      isTrue,
    );
    expect(
      tester.widgetList<Math>(find.byType(Math)).map((math) => math.mathStyle),
      [MathStyle.text, MathStyle.text, MathStyle.display, MathStyle.display],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('only delegates link taps and renders images without loading', (
    tester,
  ) async {
    final links = <String>[];
    await _pump(tester, '''
[课程原文](dansheng-course:42)

![公式截图](https://example.test/formula.png)

<img src="https://example.test/hidden.png">
''', onLink: links.add);

    expect(find.byType(Image), findsNothing);
    expect(find.text('公式截图'), findsOneWidget);
    expect(links, isEmpty);
    await tester.tap(find.text('课程原文'));
    expect(links, ['dansheng-course:42']);
  });

  testWidgets('keeps code literal and copies the original code text', (
    tester,
  ) async {
    final clipboard = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    const code = r'''
  "$x$ \(y\) $$z$$ \[w\]"
  <img> & [link](https://example.test)
''';
    final literal = code.trimRight();
    await _pump(
      tester,
      r'Inline code: `$x$`.'
      '\n\n```dart\n$code```',
    );

    expect(find.byType(Math), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.text('dart'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text(literal)).style?.fontFamily,
      'monospace',
    );
    await tester.tap(find.byTooltip('复制代码'));
    await tester.pump();
    expect(clipboard, [literal]);
  });

  testWidgets('keeps incomplete math and code visible while streaming', (
    tester,
  ) async {
    await _pump(tester, r'Unfinished \(x + ');
    expect(find.textContaining(r'\(x +'), findsOneWidget);
    expect(find.byType(Math), findsNothing);

    await _pump(tester, r'Unfinished \(x + 1\)');
    expect(find.byType(Math), findsOneWidget);

    await _pump(
      tester,
      '```\n'
      r'print("$x$");',
    );
    expect(find.text(r'print("$x$");'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
    expect(find.byType(Math), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid TeX falls back to its original source', (tester) async {
    await _pump(tester, r'Broken $\frac{$');
    expect(find.text(r'$\frac{$'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long display math, inline math and code can scroll at 2x text', (
    tester,
  ) async {
    final expression = List.filled(48, 'x').join(' + ');
    final code = List.filled(24, 'veryLongName').join('.');
    await _pump(
      tester,
      r'Inline $\displaystyle ' +
          expression +
          r'$.' +
          '\n\n\\[\n$expression\n\\]\n\n~~~very-long-language-that-will-ellipsize\n$code\n~~~',
      width: 175,
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    final scrolling = tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .where((state) => state.position.maxScrollExtent > 0)
        .toList();
    expect(scrolling, hasLength(3));
    final codeScroll = find.ancestor(
      of: find.text(code),
      matching: find.byType(Scrollable),
    );
    await tester.drag(codeScroll, const Offset(-110, 0));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(codeScroll).position.pixels,
      greaterThan(0),
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  String answer, {
  ValueChanged<String>? onLink,
  double width = 480,
  double textScale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: AgentAnswerContent(data: answer, onLink: onLink ?? (_) {}),
          ),
        ),
      ),
    ),
  ),
);
