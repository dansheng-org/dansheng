// SPDX-License-Identifier: GPL-3.0-or-later

// --- Shared parsing helpers -------------------------------------------------

/// Core wraps each row as `{external_id, payload, ...}`; fixtures may not.
Map<String, dynamic> payloadOf(Map<String, dynamic> json) =>
    json['payload'] is Map<String, dynamic>
    ? json['payload'] as Map<String, dynamic>
    : json;

/// The rows of a list response, or the single row of a detail response
/// (core returns detail reads as a one-element list).
List<Map<String, dynamic>> rowsOf(dynamic value) => switch (value) {
  final List list => list.whereType<Map<String, dynamic>>().toList(),
  final Map<String, dynamic> map => [map],
  _ => const [],
};

DateTime? parseTime(dynamic value) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? null : DateTime.tryParse(text)?.toLocal();
}

double? parseDouble(dynamic value) =>
    value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');

int? parseInt(dynamic value) =>
    value is int ? value : int.tryParse(value?.toString() ?? '');

/// Campus time (UTC+8) formatted as "11月8日 23:59".
String formatCampusTime(DateTime? time) {
  if (time == null) return '';
  final local = time.toUtc().add(const Duration(hours: 8));
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '${local.month}月${local.day}日 $h:$m';
}

/// Score without trailing zeros ("85", "92.5").
String formatScore(double value) {
  final text = value.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Canvas HTML reduced to readable plain text. Content is shown as inert text;
/// no markup, script or link is ever interpreted.
String plainText(String? html) {
  if (html == null || html.isEmpty) return '';
  var text = html
      .replaceAll(
        RegExp(
          r'<(script|style)[^>]*>.*?</\1>',
          caseSensitive: false,
          dotAll: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</(p|div|h[1-6]|li|tr|blockquote|pre)>', caseSensitive: false),
        '\n',
      )
      .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const entities = {
    '&nbsp;': ' ',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
  };
  entities.forEach((k, v) => text = text.replaceAll(k, v));
  text = text.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
    return code == null || code > 0x10FFFF ? '' : String.fromCharCode(code);
  });
  text = text.replaceAll('&amp;', '&');
  return text
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

// --- Own submission -----------------------------------------------------------

class CanvasSubmissionComment {
  final String? authorName;
  final String text;
  final DateTime? createdAt;
  const CanvasSubmissionComment({
    this.authorName,
    required this.text,
    this.createdAt,
  });
}

/// The signed-in student's own submission of one assignment.
class CanvasSubmission {
  final String assignmentId;
  final String? workflowState;
  final DateTime? submittedAt;
  final DateTime? gradedAt;
  final double? score;
  final String? grade;
  final int? attempt;
  final bool late;
  final bool missing;
  final bool excused;
  final List<String> attachmentNames;
  final List<CanvasSubmissionComment> comments;

  const CanvasSubmission({
    required this.assignmentId,
    this.workflowState,
    this.submittedAt,
    this.gradedAt,
    this.score,
    this.grade,
    this.attempt,
    this.late = false,
    this.missing = false,
    this.excused = false,
    this.attachmentNames = const [],
    this.comments = const [],
  });

  factory CanvasSubmission.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    return CanvasSubmission(
      assignmentId: p['assignment_id']?.toString() ?? '',
      workflowState: p['workflow_state']?.toString(),
      submittedAt: parseTime(p['submitted_at']),
      gradedAt: parseTime(p['graded_at']),
      score: parseDouble(p['score']),
      grade: p['grade']?.toString(),
      attempt: parseInt(p['attempt']),
      late: p['late'] == true,
      missing: p['missing'] == true,
      excused: p['excused'] == true,
      attachmentNames: [
        for (final a in rowsOf(p['attachments']))
          (a['display_name'] ?? a['filename'] ?? '附件').toString(),
      ],
      comments: [
        for (final c in rowsOf(p['submission_comments']))
          if (plainText(c['comment']?.toString()).isNotEmpty)
            CanvasSubmissionComment(
              authorName: c['author_name']?.toString(),
              text: plainText(c['comment']?.toString()),
              createdAt: parseTime(c['created_at']),
            ),
      ],
    );
  }

  bool get _handedIn =>
      submittedAt != null ||
      const {'submitted', 'pending_review'}.contains(workflowState);

  /// Handed in (on time or late), graded or excused, so nothing is owed.
  bool get isDone => excused || _handedIn || workflowState == 'graded';

  String get statusLabel {
    if (excused) return '已免除';
    if (_handedIn) return late ? '迟交' : '已提交';
    if (workflowState == 'graded') return '已评分';
    if (missing) return '缺交';
    return '未提交';
  }

  /// "85 分", a letter grade, or null when nothing is posted.
  String? get scoreLabel {
    if (score != null) return '${formatScore(score!)} 分';
    final g = grade ?? '';
    return g.isEmpty ? null : g;
  }
}

// --- Grades -----------------------------------------------------------------

/// Canvas's own course grade for the student; nothing is computed locally.
class CanvasGradeSummary {
  final double? currentScore;
  final String? currentGrade;
  final double? finalScore;
  final String? finalGrade;
  final double? currentPoints;

  const CanvasGradeSummary({
    this.currentScore,
    this.currentGrade,
    this.finalScore,
    this.finalGrade,
    this.currentPoints,
  });

  factory CanvasGradeSummary.fromJson(Map<String, dynamic> json) {
    final grades = payloadOf(json)['grades'];
    final g = grades is Map<String, dynamic>
        ? grades
        : const <String, dynamic>{};
    return CanvasGradeSummary(
      currentScore: parseDouble(g['current_score']),
      currentGrade: g['current_grade']?.toString(),
      finalScore: parseDouble(g['final_score']),
      finalGrade: g['final_grade']?.toString(),
      currentPoints: parseDouble(g['current_points']),
    );
  }

  bool get isEmpty =>
      currentScore == null &&
      (currentGrade ?? '').isEmpty &&
      finalScore == null &&
      (finalGrade ?? '').isEmpty;
}

class CanvasAssignmentGroup {
  final String id;
  final String name;
  final int position;
  final double? weight;
  final int? dropLowest;
  final int? dropHighest;

  const CanvasAssignmentGroup({
    required this.id,
    required this.name,
    this.position = 0,
    this.weight,
    this.dropLowest,
    this.dropHighest,
  });

  factory CanvasAssignmentGroup.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    final rules = p['rules'] is Map<String, dynamic>
        ? p['rules'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return CanvasAssignmentGroup(
      id: p['id']?.toString() ?? '',
      name: p['name']?.toString() ?? '作业组',
      position: parseInt(p['position']) ?? 0,
      weight: parseDouble(p['group_weight']),
      dropLowest: parseInt(rules['drop_lowest']),
      dropHighest: parseInt(rules['drop_highest']),
    );
  }
}

// --- Discussions --------------------------------------------------------------

class CanvasDiscussionTopic {
  final String id;
  final String title;
  final String? message;
  final DateTime? postedAt;
  final DateTime? lastReplyAt;
  final int replyCount;
  final String? readState;
  final bool locked;
  final bool requireInitialPost;
  final bool canSeePosts;
  final List<String> attachmentNames;

  const CanvasDiscussionTopic({
    required this.id,
    required this.title,
    this.message,
    this.postedAt,
    this.lastReplyAt,
    this.replyCount = 0,
    this.readState,
    this.locked = false,
    this.requireInitialPost = false,
    this.canSeePosts = true,
    this.attachmentNames = const [],
  });

  factory CanvasDiscussionTopic.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    return CanvasDiscussionTopic(
      id: p['id']?.toString() ?? '',
      title: p['title']?.toString() ?? '无标题讨论',
      message: p['message']?.toString(),
      postedAt: parseTime(p['posted_at']),
      lastReplyAt: parseTime(p['last_reply_at']),
      replyCount: parseInt(p['discussion_subentry_count']) ?? 0,
      readState: p['read_state']?.toString(),
      locked: p['locked'] == true || p['locked_for_user'] == true,
      requireInitialPost: p['require_initial_post'] == true,
      canSeePosts: p['user_can_see_posts'] != false,
      attachmentNames: [
        for (final a in rowsOf(p['attachments']))
          (a['display_name'] ?? a['filename'] ?? '附件').toString(),
      ],
    );
  }

  bool get unread => readState == 'unread';

  /// Latest activity, for ordering.
  DateTime? get activityAt => lastReplyAt ?? postedAt;
}

class CanvasDiscussionEntry {
  final String id;
  final String? userId;
  final String text;
  final DateTime? createdAt;
  final bool deleted;
  final List<CanvasDiscussionEntry> replies;

  const CanvasDiscussionEntry({
    required this.id,
    this.userId,
    required this.text,
    this.createdAt,
    this.deleted = false,
    this.replies = const [],
  });

  factory CanvasDiscussionEntry.fromJson(Map<String, dynamic> json) =>
      CanvasDiscussionEntry(
        id: json['id']?.toString() ?? '',
        userId: json['user_id']?.toString(),
        text: plainText(json['message']?.toString()),
        createdAt: parseTime(json['created_at']),
        deleted: json['deleted'] == true,
        replies: [
          for (final r in rowsOf(json['replies']))
            CanvasDiscussionEntry.fromJson(r),
        ],
      );
}

/// The reply tree of a discussion with participant display names.
class CanvasDiscussionView {
  final List<CanvasDiscussionEntry> entries;
  final Map<String, String> participants;
  final Set<String> unreadIds;

  const CanvasDiscussionView({
    this.entries = const [],
    this.participants = const {},
    this.unreadIds = const {},
  });

  factory CanvasDiscussionView.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    return CanvasDiscussionView(
      entries: [
        for (final e in rowsOf(p['view'])) CanvasDiscussionEntry.fromJson(e),
      ],
      participants: {
        for (final u in rowsOf(p['participants']))
          if (u['id'] != null)
            u['id'].toString(): (u['display_name'] ?? '课程成员').toString(),
      },
      unreadIds: {
        for (final id in (p['unread_entries'] as List? ?? const []))
          id.toString(),
      },
    );
  }

  int get count {
    int walk(List<CanvasDiscussionEntry> list) =>
        list.fold(0, (n, e) => n + 1 + walk(e.replies));
    return walk(entries);
  }
}

// --- Pages and module items ---------------------------------------------------

class CanvasPageSummary {
  final String slug;
  final String title;
  final DateTime? updatedAt;
  final bool frontPage;
  final bool lockedForUser;

  const CanvasPageSummary({
    required this.slug,
    required this.title,
    this.updatedAt,
    this.frontPage = false,
    this.lockedForUser = false,
  });

  factory CanvasPageSummary.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    return CanvasPageSummary(
      slug: (p['page_slug'] ?? p['url'] ?? '').toString(),
      title: p['title']?.toString() ?? '未命名页面',
      updatedAt: parseTime(p['updated_at']),
      frontPage: p['front_page'] == true,
      lockedForUser: p['locked_for_user'] == true,
    );
  }
}

class CanvasPage {
  final String slug;
  final String title;
  final String text;
  final DateTime? updatedAt;

  const CanvasPage({
    required this.slug,
    required this.title,
    required this.text,
    this.updatedAt,
  });

  factory CanvasPage.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    return CanvasPage(
      slug: (p['page_slug'] ?? p['url'] ?? '').toString(),
      title: p['title']?.toString() ?? '页面',
      text: plainText(p['body']?.toString()),
      updatedAt: parseTime(p['updated_at']),
    );
  }
}

/// One entry inside a module: a file, page, assignment, quiz, discussion,
/// external link or a plain sub-header.
class CanvasModuleItem {
  final String id;
  final String title;
  final String type;
  final int position;
  final int indent;
  final String? contentId;
  final String? pageSlug;
  final String? externalUrl;

  const CanvasModuleItem({
    required this.id,
    required this.title,
    required this.type,
    this.position = 0,
    this.indent = 0,
    this.contentId,
    this.pageSlug,
    this.externalUrl,
  });

  factory CanvasModuleItem.fromJson(Map<String, dynamic> json) {
    final p = payloadOf(json);
    return CanvasModuleItem(
      id: p['id']?.toString() ?? '',
      title: p['title']?.toString() ?? '',
      type: (p['type'] ?? p['item_type'] ?? '').toString(),
      position: parseInt(p['position']) ?? 0,
      indent: parseInt(p['indent']) ?? 0,
      contentId: p['content_id']?.toString(),
      pageSlug: (p['page_slug'] ?? p['page_url'])?.toString(),
      externalUrl: p['external_url']?.toString(),
    );
  }
}

// --- Academic syllabus --------------------------------------------------------

/// The public syllabus of an undergraduate lesson, as titled text sections.
class CourseSyllabus {
  final List<(String, String)> sections;
  const CourseSyllabus(this.sections);

  factory CourseSyllabus.fromJson(dynamic json) {
    final map = json is Map<String, dynamic>
        ? payloadOf(json)
        : const <String, dynamic>{};
    return CourseSyllabus([
      for (final s in rowsOf(map['sections']))
        if ((s['text']?.toString() ?? '').trim().isNotEmpty)
          (s['title']?.toString() ?? '', plainText(s['text']?.toString())),
    ]);
  }
}
