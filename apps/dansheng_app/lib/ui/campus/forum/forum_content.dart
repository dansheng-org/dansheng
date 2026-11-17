// SPDX-License-Identifier: GPL-3.0-or-later
// Markdown/TeX presentation follows DanXi-Dev/DanXi's GPL-3.0-or-later forum renderer.
// Copyright (C) 2021 DanXi-Dev; adaptation (C) 2026 Dansheng contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/dansheng_client.dart';
import '../campus_api.dart';
import 'forum_filter_settings.dart';
import 'forum_format.dart';
import 'forum_mention_support.dart';
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
    this.selectable = true,
  });

  final String content;
  final ValueChanged<int>? onTapHole;
  final ValueChanged<int>? onTapFloor;
  final ValueChanged<Uri>? onTapLink;
  final bool preview;

  /// False inside a floor card, whose long press opens the floor menu (as in
  /// DanXi); the menu offers copying and text selection instead.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final effectiveContent = ForumPreferences.instance.filterContent(content);
    if (preview) {
      return Text(
        cleanPreviewText(effectiveContent),
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
    final rendered = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return MarkdownBody(
          data: effectiveContent,
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
            blockquote: body.copyWith(
              fontSize: 14,
              color: colors.onSurfaceVariant,
            ),
            blockquotePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            blockquoteDecoration: BoxDecoration(
              color: theme.brightness == Brightness.dark
                  ? Colors.blue.shade900.withValues(alpha: .35)
                  : Colors.blue.shade50,
              borderRadius: BorderRadius.circular(6),
              border: Border(left: BorderSide(color: colors.primary, width: 3)),
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
            'floorMention': _FloorMentionBuilder(
              context: context,
              onTapFloor: onTapFloor,
              onTapHole: onTapHole,
            ),
            'holeMention': _HoleMentionBuilder(onTapHole: onTapHole),
          },
          imageBuilder: (uri, title, alt) =>
              _ForumImage(uri: uri, alt: alt, maxWidth: width * .8),
          onTapLink: (_, href, _) => _openLink(context, href),
        );
      },
    );
    return selectable ? SelectionArea(child: rendered) : rendered;
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = Uri.tryParse(href ?? '');
    if (uri == null) return;
    final id = int.tryParse(uri.path);
    if (id != null && uri.scheme == 'dansheng-hole') {
      if (onTapHole != null) {
        onTapHole!(id);
        return;
      }
    }
    if (id != null && uri.scheme == 'dansheng-floor') {
      if (onTapFloor != null) {
        onTapFloor!(id);
        return;
      }
      final cached = ForumFloorCache.instance.getFloor(id);
      if (cached != null) {
        await showFloorDetailModal(context, floor: cached);
        return;
      }
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
                builder: (viewer) => Scaffold(
                  appBar: AppBar(
                    title: const Text('查看图片'),
                    actions: [
                      IconButton(
                        tooltip: '保存到手机',
                        icon: const Icon(Icons.download_rounded),
                        onPressed: () =>
                            saveForumImage(viewer, _fullSizeImage(uri)),
                      ),
                    ],
                  ),
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
            onLongPress: () => _imageMenu(context),
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

  void _imageMenu(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: ListTile(
        leading: const Icon(Icons.download_rounded),
        title: const Text('保存图片到手机'),
        onTap: () {
          Navigator.of(sheet).pop();
          saveForumImage(context, _fullSizeImage(uri));
        },
      ),
    ),
  );

  Uri _fullSizeImage(Uri source) => source.host == 'image.fduhole.com'
      ? source.replace(path: source.path.replaceAll('.md.', '.'))
      : source;
}

class _FloorMentionBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  final ValueChanged<int>? onTapFloor;
  final ValueChanged<int>? onTapHole;

  _FloorMentionBuilder({
    required this.context,
    this.onTapFloor,
    this.onTapHole,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final floorId = int.tryParse(element.textContent);
    if (floorId == null) return null;
    return ForumMentionQuoteWidget(
      id: floorId,
      isFloor: true,
      onTap: () {
        final cached = ForumFloorCache.instance.getFloor(floorId);
        if (cached != null) {
          showFloorDetailModal(
            context,
            floor: cached,
            onJumpToFloor: onTapFloor != null
                ? () => onTapFloor!(floorId)
                : null,
          );
        } else if (onTapFloor != null) {
          onTapFloor!(floorId);
        }
      },
    );
  }
}

class _HoleMentionBuilder extends MarkdownElementBuilder {
  final ValueChanged<int>? onTapHole;

  _HoleMentionBuilder({this.onTapHole});

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final holeId = int.tryParse(element.textContent);
    if (holeId == null) return null;
    return ForumMentionQuoteWidget(
      id: holeId,
      isFloor: false,
      onTap: onTapHole != null ? () => onTapHole!(holeId) : null,
    );
  }
}

/// Largest picture kept on the phone; the host enforces the same bound.
const _maxSavedImage = 30 * 1024 * 1024;

/// Fetches a forum picture again (full size) and saves it to the phone's gallery.
/// Only public https pictures are fetched; the host checks the type and size.
Future<void> saveForumImage(BuildContext context, Uri uri) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) =>
      messenger?.showSnackBar(SnackBar(content: Text(text)));
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    say('这张图片无法保存');
    return;
  }
  say('正在保存图片…');
  try {
    final bytes = await _download(uri);
    final mime = imageMimeOf(bytes);
    if (mime == null) {
      say('这张图片无法保存');
      return;
    }
    final name = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    final saved = await CampusApi(DanshengClient()).call('campus.saveImage', {
      'name': name,
      'mime': mime,
      'data_base64': base64Encode(bytes),
    });
    final where = saved is Map ? saved['location'] : null;
    say(where == null ? '已保存到相册' : '已保存到$where');
  } on PlatformException catch (e) {
    if (e.code != 'Cancelled') say(campusError(e));
  } catch (_) {
    say('图片下载失败，请稍后重试');
  }
}

Future<Uint8List> _download(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw const HttpException('status');
    final out = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      out.add(chunk);
      if (out.length > _maxSavedImage) throw const HttpException('too large');
    }
    return out.takeBytes();
  } finally {
    client.close(force: true);
  }
}

/// The picture type from its first bytes; null when it is not a picture.
@visibleForTesting
String? imageMimeOf(List<int> b) {
  bool starts(List<int> sig, [int at = 0]) =>
      b.length >= at + sig.length &&
      List.generate(sig.length, (i) => i).every((i) => b[at + i] == sig[i]);
  if (starts([0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (starts([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts([0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return null;
}
