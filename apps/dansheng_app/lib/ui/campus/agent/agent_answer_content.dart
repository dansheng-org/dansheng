// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders a model answer. The caller decides which links may be opened.
class AgentAnswerContent extends StatelessWidget {
  const AgentAnswerContent({
    super.key,
    required this.data,
    required this.onLink,
  });

  final String data;
  final ValueChanged<String> onLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SelectionArea(
      child: MarkdownBody(
        data: data,
        fitContent: false,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        blockSyntaxes: [const _DisplayMathSyntax()],
        inlineSyntaxes: [_InlineMathSyntax()],
        styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
          codeblockDecoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          tableColumnWidth: const FlexColumnWidth(),
        ),
        builders: {
          'agent-math': _MathBuilder(display: false),
          'agent-display-math': _MathBuilder(display: true),
          'agent-math-block': _MathBuilder(display: true, block: true),
          'img': _ImageAltBuilder(),
          'pre': _CodeBlockBuilder(),
        },
        onTapLink: (_, href, _) {
          if (href != null && href.isNotEmpty) onLink(href);
        },
      ),
    );
  }
}

class _InlineMathSyntax extends md.InlineSyntax {
  _InlineMathSyntax()
    : super(
        r'(?<!\$)\$\$(?!\$)((?:\\[\s\S]|[^\\$]|\$(?!\$))+?)\$\$(?!\$)'
        r'|\\\[((?:\\(?!\])[\s\S]|[^\\])+?)\\\]'
        r'|(?<!\$)\$(?![\s$])((?:\\[^\n]|[^\\$\n])+?)(?<!\s)\$(?![\d$])'
        r'|\\\(((?:\\(?!\))[^\n]|[^\\\n])+?)\\\)'
        r'|(\\[\[(])',
      );

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // Keep an unfinished backslash delimiter visible while a reply streams.
    final unfinished = match[5];
    if (unfinished != null) {
      parser.addNode(md.Text(unfinished));
      return true;
    }
    final display = match[1] ?? match[2];
    final element = md.Element.text(
      display == null ? 'agent-math' : 'agent-display-math',
      display ?? match[3] ?? match[4]!,
    );
    element.attributes['source'] = match[0]!;
    parser.addNode(element);
    return true;
  }
}

class _DisplayMathSyntax extends md.BlockSyntax {
  const _DisplayMathSyntax();

  static final _opening = RegExp(r'^ {0,3}(\$\$(?!\$)|\\\[)');
  static final _dollarEnd = RegExp(r'\\.|(\$\$)(?!\$)');
  static final _bracketEnd = RegExp(r'(\\\])|\\.');
  static final _fence = const md.FencedCodeBlockSyntax().pattern;

  @override
  RegExp get pattern => _opening;

  // Only interrupt a Markdown block when the display really closes on its
  // own line. This also leaves code fences to the Markdown parser.
  ({int lines, String tex, String source})? _read(md.BlockParser parser) {
    final opening = _opening.firstMatch(parser.current.content);
    if (opening == null) return null;
    final endPattern = opening[1] == r'$$' ? _dollarEnd : _bracketEnd;
    final content = StringBuffer();
    for (var offset = 0; ; offset++) {
      final line = parser.peek(offset)?.content;
      if (line == null || (offset > 0 && _fence.hasMatch(line))) return null;
      final text = offset == 0 ? line.substring(opening.end) : line;
      final end = endPattern
          .allMatches(text)
          .where((m) => m[1] != null)
          .firstOrNull;
      if (end != null) {
        if (text.substring(end.end).trim().isNotEmpty) return null;
        content.write(text.substring(0, end.start));
        final tex = content.toString().trim();
        if (tex.isEmpty) return null;
        return (
          lines: offset + 1,
          tex: tex,
          source: opening[1]! + content.toString() + end[0]!,
        );
      }
      content.writeln(text);
    }
  }

  @override
  bool canParse(md.BlockParser parser) => _read(parser) != null;

  @override
  md.Node? parse(md.BlockParser parser) {
    final formula = _read(parser);
    if (formula == null) return null;
    for (var line = 0; line < formula.lines; line++) {
      parser.advance();
    }
    return md.Element.text('agent-math-block', formula.tex)
      ..attributes['source'] = formula.source;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder({required this.display, this.block = false});

  final bool display;
  final bool block;

  @override
  bool isBlockElement() => block;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final style = parentStyle ?? Theme.of(context).textTheme.bodyMedium;
    final math = Math.tex(
      element.textContent.trim(),
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style,
      onErrorFallback: (_) => Text(element.attributes['source']!, style: style),
    );

    Widget scroll(Widget child) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      primary: false,
      child: child,
    );

    if (!display) {
      return Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: scroll(math),
            ),
          ],
        ),
        style: style,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => scroll(
        ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: constraints.hasBoundedWidth ? constraints.maxWidth : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(child: math),
          ),
        ),
      ),
    );
  }
}

class _ImageAltBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final alt = element.attributes['alt'];
    return alt == null || alt.isEmpty
        ? const SizedBox.shrink()
        : Text.rich(TextSpan(text: alt), style: parentStyle);
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.children?.firstOrNull;
    final languageClass = code is md.Element ? code.attributes['class'] : null;
    const languagePrefix = 'language-';
    final language =
        languageClass != null && languageClass.startsWith(languagePrefix)
        ? languageClass.substring(languagePrefix.length)
        : '';
    final text = element.textContent;
    // Markdown includes a final line break in preformatted blocks.
    final source = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 12, end: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  language,
                  style: theme.textTheme.labelMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.content_copy, size: 18),
                tooltip: '复制代码',
                onPressed: () => Clipboard.setData(ClipboardData(text: source)),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Text(
            source,
            softWrap: false,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}
