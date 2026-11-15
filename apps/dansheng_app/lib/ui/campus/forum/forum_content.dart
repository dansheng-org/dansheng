// SPDX-License-Identifier: GPL-3.0-or-later
// Markdown/TeX presentation follows DanXi-Dev/DanXi's GPL-3.0-or-later forum renderer.
// Copyright (C) 2021 DanXi-Dev; adaptation (C) 2026 Dansheng contributors.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/dansheng_client.dart';
import '../campus_api.dart';
import 'forum_format.dart';
import 'forum_syntax.dart';

/// Forum body renderer. Full posts retain their formatting; previews use plain text.
class ForumContent extends StatelessWidget {
  const ForumContent({
    super.key,
    required this.content,
    this.onTapHole,
    this.onTapFloor,
    this.onTapLink,
    this.preview = false,
  });

  final String content;
  final ValueChanged<int>? onTapHole;
  final ValueChanged<int>? onTapFloor;
  final ValueChanged<Uri>? onTapLink;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    if (preview) {
      return Text(
        cleanPreviewText(content),
        maxLines: 6,
        overflow: TextOverflow.ellipsis,
      );
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge!.copyWith(
      fontSize: 16,
      height: 1.45,
    );
    return SelectionArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return MarkdownBody(
            data: content,
            softLineBreak: true,
            selectable: false,
            fitContent: false,
            extensionSet: md.ExtensionSet.gitHubFlavored,
            inlineSyntaxes: forumInlineSyntaxes(),
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: body,
              a: body.copyWith(
                color: colors.primary,
                decoration: TextDecoration.underline,
              ),
              em: body.copyWith(fontStyle: FontStyle.italic),
              strong: body.copyWith(fontWeight: FontWeight.bold),
              del: body.copyWith(decoration: TextDecoration.lineThrough),
              listBullet: body,
              blockquote: body,
              blockquotePadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              blockquoteDecoration: BoxDecoration(
                color: colors.secondaryContainer.withValues(alpha: .45),
                border: Border(
                  left: BorderSide(color: colors.primary, width: 3),
                ),
              ),
              code: body.copyWith(fontFamily: 'monospace', fontSize: 14),
              codeblockDecoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              blockSpacing: 10,
              tableColumnWidth: const FlexColumnWidth(),
            ),
            builders: {
              'forum-math': _MathBuilder(width, block: false),
              'forum-math-block': _MathBuilder(width, block: true),
              'forum-audit': _AuditBuilder(),
            },
            imageBuilder: (uri, title, alt) =>
                _ForumImage(uri: uri, alt: alt, maxWidth: width * .8),
            onTapLink: (_, href, _) => _openLink(context, href),
          );
        },
      ),
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = Uri.tryParse(href ?? '');
    if (uri == null) return;
    final id = int.tryParse(uri.path);
    if (id != null && uri.scheme == 'dansheng-hole' && onTapHole != null) {
      onTapHole!(id);
      return;
    }
    if (id != null && uri.scheme == 'dansheng-floor' && onTapFloor != null) {
      onTapFloor!(id);
      return;
    }
    if (_externalUrl(uri)) {
      if (onTapLink != null) {
        onTapLink!(uri);
        return;
      }
      try {
        await CampusApi(DanshengClient())
            .call('forum.openLink', {'url': uri.toString()});
        return;
      } on PlatformException {
        // Keep the address usable if no external browser is installed.
      }
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(uri.scheme.startsWith('dansheng-') ? '论坛引用' : '链接'),
        content: SelectableText(
          uri.scheme.startsWith('dansheng-')
              ? '${uri.scheme == 'dansheng-floor' ? '##' : '#'}${uri.path}'
              : uri.toString(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri.toString()));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }
}

bool _externalUrl(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder(this.maxWidth, {required this.block});
  final double maxWidth;
  final bool block;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final math = Math.tex(
      element.textContent,
      mathStyle: block ? MathStyle.display : MathStyle.text,
      textStyle: (parentStyle ?? const TextStyle()).copyWith(fontSize: 16),
      onErrorFallback: (_) => Text(
        element.textContent,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth,
        minWidth: block ? maxWidth : 0,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: block
            ? ConstrainedBox(
                constraints: BoxConstraints(minWidth: maxWidth),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: math,
                  ),
                ),
              )
            : math,
      ),
    );
  }
}

class _AuditBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(
    element.textContent,
    style: (parentStyle ?? Theme.of(context).textTheme.bodyLarge!).copyWith(
      backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
    ),
  );
}

class _ForumImage extends StatelessWidget {
  const _ForumImage({
    required this.uri,
    required this.alt,
    required this.maxWidth,
  });
  final Uri uri;
  final String? alt;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final sticker =
        uri.toString().startsWith('dx_') || uri.toString().startsWith('danxi_');
    if (sticker || !_externalUrl(uri)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          sticker
              ? '[表情${alt?.isNotEmpty == true ? '：$alt' : ''}]'
              : '[无法显示图片]',
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Semantics(
          label: alt?.isNotEmpty == true ? alt : '论坛图片',
          button: true,
          child: InkWell(
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('查看图片')),
                  body: Center(
                    child: InteractiveViewer(
                      minScale: .5,
                      maxScale: 5,
                      child: Image.network(
                        _fullSizeImage(uri).toString(),
                        errorBuilder: (_, _, _) => const Text('图片加载失败'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 320),
              child: Image.network(
                uri.toString(),
                fit: BoxFit.contain,
                semanticLabel: alt,
                loadingBuilder: (_, child, progress) => progress == null
                    ? child
                    : const SizedBox(
                        width: 120,
                        height: 80,
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                errorBuilder: (_, _, _) => const SizedBox(
                  width: 140,
                  height: 60,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image_outlined),
                      SizedBox(width: 8),
                      Flexible(child: Text('图片加载失败')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Uri _fullSizeImage(Uri source) => source.host == 'image.fduhole.com'
      ? source.replace(path: source.path.replaceAll('.md.', '.'))
      : source;
}
