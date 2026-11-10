// SPDX-License-Identifier: GPL-3.0-or-later

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
  var text = content;

  // LaTeX tags
  text = text.replaceAll(
    RegExp(r'<(tex|texLine)>.*?</(tex|texLine)>', dotAll: true),
    '[公式]',
  );
  text = text.replaceAll(RegExp(r'\$\$.*?\$\$', dotAll: true), '[公式]');

  // Markdown images and HTML img
  text = text.replaceAll(RegExp(r'!\[.*?\]\(.*?\)'), '[图片]');
  text = text.replaceAll(RegExp(r'<img[^>]*>'), '[图片]');

  // Mentions
  text = text.replaceAll(
    RegExp(r'<(floor|hole)Mention>.*?</(floor|hole)Mention>'),
    '',
  );

  // HTML tags
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');

  // Truncate redundant whitespace
  text = text.replaceAll(RegExp(r'\n{2,}'), '\n');
  return text.trim();
}

/// Resolves anonymous display name for a floor.
/// Floor 1 defaults to '洞主' (original poster), subsequent floors default to '热心同学' if anonymous.
String resolveAnonyname(String? anonyname, int floorNumber) {
  if (anonyname != null && anonyname.trim().isNotEmpty) {
    return anonyname.trim();
  }
  return floorNumber == 1 ? '洞主' : '热心同学';
}
