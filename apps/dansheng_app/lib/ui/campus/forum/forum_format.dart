// SPDX-License-Identifier: GPL-3.0-or-later
// Preview extraction follows DanXi-Dev/DanXi lib/page/subpage_forum.dart (GPL-3.0-or-later).
import 'package:markdown/markdown.dart' as md;

import 'forum_syntax.dart';

/// Formats an ISO8601/RFC3339 timestamp into human-readable Chinese relative time.
String formatFriendlyTime(String? timeStr) {
  if (timeStr == null || timeStr.isEmpty) return '';
  final dt = DateTime.tryParse(timeStr)?.toLocal();
  if (dt == null) return timeStr;

  final now = DateTime.now();
  final diff = now.difference(dt);

  if (diff.inSeconds < 60) {
    return '刚刚';
  } else if (diff.inMinutes < 60) {
    return '${diff.inMinutes}分钟前';
  } else if (diff.inHours < 24) {
    return '${diff.inHours}小时前';
  } else if (diff.inDays < 7) {
    return '${diff.inDays}天前';
  } else if (dt.year == now.year) {
    return '${_twoDigits(dt.month)}-${_twoDigits(dt.day)} ${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}';
  } else {
    return '${dt.year}-${_twoDigits(dt.month)}-${_twoDigits(dt.day)}';
  }
}

String _twoDigits(int n) => n >= 10 ? '$n' : '0$n';

/// Cleans and sanitizes post preview text:
/// - Replaces TeX tags with [公式]
/// - Replaces images with [图片]
/// - Removes HTML tags
String cleanPreviewText(String? content) {
  if (content == null || content.isEmpty) return '';
  final nodes = md.Document(
    encodeHtml: false,
    inlineSyntaxes: forumInlineSyntaxes(),
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parseLines(content.split('\n'));
  String extract(md.Node node, {required bool mentions}) {
    if (node is md.Text) return node.text;
    if (node is! md.Element) return '';
    if (node.tag.startsWith('forum-math')) return '[公式]';
    if (node.tag == 'img') {
      final src = node.attributes['src'] ?? '';
      return src.startsWith('dx_') || src.startsWith('danxi_')
          ? '[表情]'
          : '[图片]';
    }
    if (node.tag == 'a' &&
        (node.attributes['href'] ?? '').startsWith('dansheng-') &&
        !mentions) {
      return '';
    }
    final text = (node.children ?? const <md.Node>[])
        .map((child) => extract(child, mentions: mentions))
        .join();
    return const {
          'p',
          'li',
          'blockquote',
          'pre',
          'h1',
          'h2',
          'h3',
          'tr',
        }.contains(node.tag)
        ? '$text\n'
        : text;
  }

  String flatten(bool mentions) => nodes
      .map((node) => extract(node, mentions: mentions))
      .join()
      .replaceAll(RegExp(r'<img\b[^>]*>', caseSensitive: false), '[图片]')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  final text = flatten(false);
  return text.isEmpty ? flatten(true) : text;
}

/// Resolves anonymous display name for a floor.
/// Floor 1 defaults to '洞主' (original poster), subsequent floors default to '热心同学' if anonymous.
String resolveAnonyname(String? anonyname, int floorNumber) {
  if (anonyname != null && anonyname.trim().isNotEmpty) {
    return anonyname.trim();
  }
  return floorNumber == 1 ? '洞主' : '热心同学';
}
