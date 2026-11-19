// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import '../ui/campus/forum/forum_models.dart';
import '../ui/campus/learning/models/canvas_models.dart';
import 'agent_campus_link.dart';
import 'agent_session.dart';
import 'agent_types.dart';

const _query = {'type': 'string', 'maxLength': 80};
const _courseId = {'type': 'string', 'maxLength': 24};

AgentToolRegistry campusToolRegistry({
  required Future<(dynamic, bool)> Function(String method, Json params) read,
  required String? Function() activeAccount,
  required bool Function() forumEnabled,
  AgentTool? webTool,
  Iterable<AgentTool> extraTools = const [],
}) => AgentToolRegistry(
  activeAccount: activeAccount,
  sourceAvailable: (source) => switch (source) {
    AgentSourceKind.forum => forumEnabled(),
    AgentSourceKind.web => webTool != null,
    _ => true,
  },
  tools: [
    ?webTool,
    _tool(
      'campus_courses',
      '查阅当前账号的 Canvas 课程，返回课程 ID、名称、学期。默认只看本学期。'
          '用户给出课程名称时传 query，按名称搜索包括历史课程。',
      AgentSourceKind.learning,
      '查询 Canvas 课程',
      {
        'include_archive': {'type': 'boolean'},
        'query': _query,
      },
      read: (args) async {
        final (raw, cached) = await read('canvas.courses.sync', {});
        final today = _campusToday();
        final query = (args['query'] as String?)?.trim() ?? '';
        final courses = rowsOf(raw)
            .map(CanvasCourse.fromJson)
            .where(
              (course) =>
                  AgentCampusLink.isCanvasId(course.id) &&
                  (args['include_archive'] == true ||
                      query.isNotEmpty ||
                      course.belongsToTerm(today)) &&
                  (agentCanvasNameMatches(course.name, query) ||
                      agentCanvasNameMatches(course.courseCode ?? '', query)),
            );
        return _rows(
          'Canvas 课程',
          cached,
          courses.map((course) {
            final name = _excerpt(course.name);
            return (
              {
                'course_id': course.id,
                'name': name,
                if (course.termName case final String term)
                  'term': _excerpt(term),
              },
              _link(
                name.isEmpty ? '课程 #${course.id}' : name,
                'course/${course.id}',
              ),
            );
          }),
          limit: 25,
        );
      },
    ),
    _tool(
      'campus_assignments',
      '按课程 ID 查 Canvas 作业。默认只看尚未到截止时间的作业，包含截止时间未知的项目。'
          '按名称查找（例如 Assignment 1）时传 query，会搜索已截止作业；'
          '匹配唯一时附作业说明。已知 assignment_id 时可直接查询详情。',
      AgentSourceKind.learning,
      '查询 Canvas 作业',
      {
        'course_id': _courseId,
        'include_past': {'type': 'boolean'},
        'query': _query,
        'assignment_id': _courseId,
      },
      requiredFields: ['course_id'],
      read: (args) async {
        final courseId = args['course_id'] as String;
        if (!AgentCampusLink.isCanvasId(courseId)) {
          throw const AgentFailure('请提供 Canvas 课程列表返回的有效课程 ID。');
        }
        final query = (args['query'] as String?)?.trim() ?? '';
        final assignmentId = args['assignment_id'] as String?;
        final targeted = query.isNotEmpty || assignmentId != null;
        if (assignmentId != null && !AgentCampusLink.isCanvasId(assignmentId)) {
          throw const AgentFailure('请提供 Canvas 作业列表返回的有效作业 ID。');
        }
        final (raw, cached) = await read('canvas.assignments.sync', {
          'course_id': courseId,
        });
        final now = DateTime.now();
        final assignments =
            rowsOf(raw)
                .where((row) => payloadOf(row)['published'] != false)
                .map((row) => CanvasAssignment.fromJson(row, courseId))
                .where(
                  (item) =>
                      (!targeted || item.courseId == courseId) &&
                      (assignmentId == null || item.id == assignmentId) &&
                      agentCanvasNameMatches(item.name, query) &&
                      (args['include_past'] == true ||
                          targeted ||
                          !(item.dueAt?.isBefore(now) ?? false)),
                )
                .toList()
              ..sort((a, b) {
                final aDue = a.dueAt?.millisecondsSinceEpoch;
                final bDue = b.dueAt?.millisecondsSinceEpoch;
                return (aDue ?? 8640000000000000).compareTo(
                  bDue ?? 8640000000000000,
                );
              });
        return _rows(
          'Canvas 作业',
          cached,
          assignments.map((item) {
            final title = _excerpt(item.name);
            return (
              {
                'title': title,
                if (AgentCampusLink.isCanvasId(item.id))
                  'assignment_id': item.id,
                'due_at': item.dueAt == null ? null : _campusIso(item.dueAt!),
                if (targeted && assignments.length == 1)
                  ...agentAssignmentDetails(item),
              },
              item.courseId == courseId
                  ? _link(
                      title.isEmpty ? '作业 #${item.id}' : title,
                      'assignment/$courseId/${item.id}',
                    )
                  : null,
            );
          }),
          fields: {'course_id': courseId, 'campus_time': _campusIso(now)},
        );
      },
    ),
    _tool(
      'campus_forum_search',
      '搜索复旦树洞（旦挞茶楼）的帖子和回复，返回编号、时间和可见正文的短摘录。',
      AgentSourceKind.forum,
      '搜索复旦树洞',
      {'query': _query},
      requiredFields: ['query'],
      read: (args) async {
        final (raw, cached) = await read('community.tea.search', {
          'query': (args['query'] as String).trim(),
          'offset': 0,
          'size': 8,
        });
        return _rows(
          '复旦树洞（旦挞茶楼）',
          cached,
          forumRowsOf(raw)
              .map(ForumSearchResult.fromJson)
              .where((hit) => !hit.deleted && hit.fold.isEmpty)
              .map((hit) {
                final thread = hit.holeId;
                final floor = hit.floorId;
                return (
                  {
                    'thread_id': hit.holeId,
                    if (hit.floorId case final int id) 'floor_id': id,
                    'posted_at': _excerpt(hit.timeCreated, limit: 40),
                    'excerpt': _excerpt(hit.content, limit: 280),
                  },
                  floor == null
                      ? _link('树洞 #$thread', 'forum/$thread')
                      : _link(
                          '树洞 #$thread · 楼层 #$floor',
                          'forum/$thread/$floor',
                        ),
                );
              }),
          limit: 8,
        );
      },
    ),
    _tool(
      'campus_notices',
      '查询复旦教务官方公告首页摘要。graduate 为 true 时查研究生院公告。',
      AgentSourceKind.campus,
      '查询教务公告',
      {
        'graduate': {'type': 'boolean'},
      },
      read: (args) async {
        final graduate = args['graduate'] == true;
        final (raw, cached) = await read('fudan.notices', {
          if (graduate) 'level': 'graduate',
        });
        return _rows(
          graduate ? '复旦研究生院公告' : '复旦本科教务公告',
          cached,
          rowsOf(raw).map(payloadOf).map((item) {
            final title = _excerpt(item['title']);
            return (
              {
                'title': title,
                'published_on': _excerpt(item['published_on'], limit: 24),
              },
              item['url'] is String
                  ? AgentCampusLink.fromNotice(title, item['url'] as String)
                  : null,
            );
          }),
        );
      },
    ),
    _tool(
      'campus_library',
      '查询各校区图书馆在馆人数。',
      AgentSourceKind.campus,
      '查询图书馆客流',
      {},
      read: (_) async {
        final (raw, cached) = await read('fudan.library.occupancy', {});
        final link = _link('图书馆客流', 'library');
        return _rows(
          '复旦图书馆客流',
          cached,
          rowsOf(raw)
              .map(payloadOf)
              .map(
                (item) => (
                  {
                    'campus': _excerpt(item['campus']),
                    'inside': parseInt(item['inside']),
                  },
                  link,
                ),
              ),
        );
      },
    ),
    ...extraTools,
  ],
);

AgentCampusLink? _link(String title, String path) =>
    AgentCampusLink.fromJson({'title': title, 'url': 'dansheng://agent/$path'});

final _links = RegExp(r'https?://[^\s<>()]+', caseSensitive: false);
final _whitespace = RegExp(r'\s+');
final _nameSeparators = RegExp(r'[\s\p{P}]+', unicode: true);
final _visibleAssignmentFile = RegExp(
  r'<a\b[^>]*(?:href|data-api-endpoint)\s*=\s*[^>]*?/files/[0-9]+',
  caseSensitive: false,
);

bool agentCanvasNameMatches(String title, String query) {
  final normalized = query.toLowerCase().replaceAll(_nameSeparators, '');
  if (normalized.isEmpty) return true;
  final numberSuffix = RegExp(r'[0-9]$').hasMatch(normalized)
      ? '(?![0-9])'
      : '';
  return RegExp('${RegExp.escape(normalized)}$numberSuffix')
      .hasMatch(title.toLowerCase().replaceAll(_nameSeparators, ''));
}

Json agentAssignmentDetails(CanvasAssignment item) {
  if (item.lockedForUser) return {'locked': true};
  final markup = item.description;
  if (markup == null || markup.isEmpty) return {};
  final text = plainText(markup).replaceAll(_links, '').trim();
  const limit = 3000;
  final excerpt = String.fromCharCodes(text.runes.take(limit));
  return {
    if (excerpt.isNotEmpty) 'description': excerpt,
    if (excerpt.length < text.length) 'description_truncated': true,
    if (_visibleAssignmentFile.hasMatch(markup)) 'has_file_links': true,
  };
}

String _excerpt(Object? value, {int limit = 140}) {
  if (value is! String) return '';
  return String.fromCharCodes(
    value
        .replaceAll(_links, '')
        .replaceAll(_whitespace, ' ')
        .trim()
        .runes
        .take(limit),
  );
}

DateTime _campusToday() => DateTime.now().toUtc().add(const Duration(hours: 8));

String _campusIso(DateTime value) => value
    .toUtc()
    .add(const Duration(hours: 8))
    .toIso8601String()
    .replaceFirst(RegExp(r'\.\d+Z$'), '+08:00');

AgentTool _tool(
  String name,
  String description,
  AgentSourceKind source,
  String label,
  Json properties, {
  List<String> requiredFields = const [],
  required Future<Json> Function(Json) read,
}) => AgentTool(
  spec: AgentToolSpec(name, description, {
    'type': 'object',
    'properties': properties,
    'required': requiredFields,
    'additionalProperties': false,
  }),
  source: source,
  label: label,
  read: read,
);

Json _rows(
  String source,
  bool cached,
  Iterable<(Json, AgentCampusLink?)> records, {
  int limit = 15,
  Json fields = const {},
}) {
  final rows = <Json>[];
  final links = <Json>[];
  final seen = <String>{};
  final result = {
    ...fields,
    'source': source,
    'cached': cached,
    'truncated': true,
    'records': rows,
    'campus_links': links,
  };
  for (final (record, link) in records) {
    if (rows.length == limit) return result;
    final url = link?.uri.toString();
    rows.add({...record, 'link': ?url});
    final addedLink = url != null && seen.add(url);
    if (addedLink) links.add(link!.toJson());
    // The session accepts 12,000 encoded characters. Reserve one for false.
    if (jsonEncode(result).length >= 12000) {
      rows.removeLast();
      if (addedLink) links.removeLast();
      return result;
    }
  }
  return result..['truncated'] = false;
}
