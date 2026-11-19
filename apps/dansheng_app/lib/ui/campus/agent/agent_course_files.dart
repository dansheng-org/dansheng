// SPDX-License-Identifier: GPL-3.0-or-later

import '../../../agent/agent_campus_link.dart';
import '../../../agent/agent_session.dart';
import '../../../agent/agent_types.dart';
import '../../../agent/campus_tools.dart';
import '../campus_api.dart';
import '../learning/models/canvas_models.dart';
import 'agent_remote_files.dart';

const _source = 'Canvas 课程文件';
const _canvasHost = 'elearning.fudan.edu.cn';
const _idField = {'type': 'string', 'maxLength': 24};

Iterable<AgentTool> courseFileAgentTools(CampusApi api) => [
  AgentTool(
    spec: const AgentToolSpec(
      'campus_file_context',
      '按名称查找文件所属的 Canvas 课程。提供课程 ID 后可按作业名称查找作业 ID；'
          '作业名称唯一匹配时附作业说明，包括已截止作业。',
      {
        'type': 'object',
        'properties': {'course_id': _idField, 'query': agentFileQueryField},
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.files,
    label: '查找文件所属课程或作业',
    read: (args) => _fileContext(api, args),
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_course_files',
      '按 Canvas 课程 ID 列出可读取的 PDF、图片和 UTF-8 文本。'
          '可按文件名关键词筛选。提供作业 ID 时，只查该作业说明直接链接的文件，包括课程文件列表未收录的链接。',
      {
        'type': 'object',
        'properties': {
          'course_id': _idField,
          'assignment_id': _idField,
          'query': agentFileQueryField,
        },
        'required': ['course_id'],
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.files,
    label: '查询 Canvas 课程文件',
    read: (args) => _listCourseFiles(api, args),
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_read_course_file',
      '附上 Canvas 课程文件列表返回的原始文件。请使用同一条结果的课程 ID、文件 ID 及作业 ID（如果有）。',
      {
        'type': 'object',
        'properties': {
          'course_id': _idField,
          'file_id': _idField,
          'assignment_id': _idField,
        },
        'required': ['course_id', 'file_id'],
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.files,
    label: '读取 Canvas 课程文件',
    timeout: agentFileReadTimeout,
    read: (args) => _readCourseFile(api, args),
  ),
];

Future<Json> _fileContext(CampusApi api, Json args) async {
  final query = agentFileQuery(args);
  final courseId = args.containsKey('course_id')
      ? _canvasId(args['course_id'])
      : null;
  final result = await callAgentFileApi(
    api,
    courseId == null ? 'canvas.courses.sync' : 'canvas.assignments.sync',
    {'course_id': ?courseId},
  );
  if (result is! List) throw const AgentFailure('无法读取 Canvas 课程或作业列表。');
  final records = <Json>[];
  final links = <Json>[];
  CanvasAssignment? matchedAssignment;
  for (final row in rowsOf(result)) {
    late final Json record;
    late final String title;
    late final String path;
    if (courseId == null) {
      final course = CanvasCourse.fromJson(row);
      if (!AgentCampusLink.isCanvasId(course.id) ||
          !agentFileMatches(query, [course.name, course.courseCode ?? ''])) {
        continue;
      }
      title = agentFileLabel(course.name);
      path = 'course/${course.id}';
      record = {'course_id': course.id, 'name': title};
    } else {
      final assignment = CanvasAssignment.fromJson(row, courseId);
      if (!AgentCampusLink.isCanvasId(assignment.id) ||
          assignment.courseId != courseId ||
          assignment.lockedForUser ||
          payloadOf(row)['published'] == false ||
          !agentCanvasNameMatches(assignment.name, query)) {
        continue;
      }
      matchedAssignment = assignment;
      title = agentFileLabel(assignment.name);
      path = 'assignment/$courseId/${assignment.id}';
      record = {
        'course_id': courseId,
        'assignment_id': assignment.id,
        'name': title,
      };
    }
    final url = 'dansheng://agent/$path';
    records.add({...record, 'url': url});
    links.add({'url': url, 'title': title});
    if (records.length == 20) break;
  }
  if (query.isNotEmpty && records.length == 1 && matchedAssignment != null) {
    records.single.addAll(agentAssignmentDetails(matchedAssignment));
  }
  return {'source': _source, 'records': records, 'campus_links': links};
}

Future<int> clearAgentRemoteFiles(CampusApi api) async {
  final result = await callAgentFileApi(api, 'agent.remoteFile.clear');
  if (result case {'deleted': final int deleted} when deleted >= 0) {
    return deleted;
  }
  throw const AgentFailure('无法确认已清理的文件数量。');
}

Future<Json> _listCourseFiles(CampusApi api, Json args) async {
  final courseId = _canvasId(args['course_id']);
  final assignmentId = _optionalAssignmentId(args);
  final query = agentFileQuery(args);
  final params = {'course_id': courseId};
  final linked = assignmentId == null
      ? null
      : await _assignmentFiles(api, courseId, assignmentId, params);
  final records = <Json>[];
  var truncated = false;
  void addRecord(String id, String name, String? mime, int? size) {
    if (records.length == 25) {
      truncated = true;
      return;
    }
    records.add({
      'file_id': id,
      'assignment_id': ?assignmentId,
      'name': agentFileLabel(name),
      'mime_type': ?mime,
      'size': ?size,
    });
  }

  if (linked == null || linked.isNotEmpty) {
    final result = await callAgentFileApi(api, 'canvas.materials.sync', params);
    if (result is! List) {
      throw const AgentFailure('无法读取这门课程的文件列表。');
    }
    final listedIds = <String>{};
    for (final row in rowsOf(result)) {
      final file = CanvasMaterial.fromJson(row, courseId);
      if (!AgentCampusLink.isCanvasId(file.id) ||
          (linked != null && !linked.containsKey(file.id)) ||
          !listedIds.add(file.id)) {
        continue;
      }
      final size = file.size;
      final linkedName = linked?[file.id] ?? '';
      final mime = agentFileMimeType(file.contentType, [
        file.filename,
        file.displayName,
        linkedName,
      ]);
      if (file.courseId != courseId ||
          file.lockedForUser ||
          payloadOf(row)['hidden_for_user'] == true ||
          mime == null ||
          !agentFileSizeSupported(mime, size) ||
          !agentFileMatches(query, [
            file.filename,
            file.displayName,
            linkedName,
          ])) {
        continue;
      }
      addRecord(
        file.id,
        file.displayName,
        mime,
        size != null && size >= 0 ? size : null,
      );
      if (truncated) break;
    }
    if (linked != null && !truncated) {
      for (final entry in linked.entries) {
        if (listedIds.contains(entry.key) ||
            !agentFileMatches(query, [entry.value])) {
          continue;
        }
        addRecord(
          entry.key,
          entry.value.isEmpty ? '作业附件' : entry.value,
          agentFileMimeType(null, [entry.value]),
          null,
        );
        if (truncated) break;
      }
    }
  }
  return {
    'source': _source,
    'course_id': courseId,
    'assignment_id': ?assignmentId,
    'records': records,
    'truncated': truncated,
  };
}

Future<Json> _readCourseFile(CampusApi api, Json args) {
  final courseId = _canvasId(args['course_id']);
  final fileId = _canvasId(args['file_id']);
  final assignmentId = _optionalAssignmentId(args);
  return readAgentRemoteFile(api, _source, {
    'source': 'canvas',
    'course_id': courseId,
    'file_id': fileId,
    'assignment_id': ?assignmentId,
  });
}

Future<Map<String, String>> _assignmentFiles(
  CampusApi api,
  String courseId,
  String assignmentId,
  Json params,
) async {
  final result = await callAgentFileApi(api, 'canvas.assignments.sync', params);
  if (result is! List) {
    throw const AgentFailure('无法读取这门课程的作业。');
  }
  for (final row in rowsOf(result)) {
    if (payloadOf(row)['published'] == false) continue;
    final assignment = CanvasAssignment.fromJson(row, courseId);
    if (assignment.id != assignmentId || assignment.courseId != courseId) {
      continue;
    }
    if (assignment.lockedForUser) break;
    return agentAssignmentFileLinks(assignment.description ?? '', courseId);
  }
  throw const AgentFailure('这门课程中没有找到可查看的指定作业。');
}

/// Same-campus file identifiers and display names linked in assignment HTML.
Map<String, String> agentAssignmentFileLinks(String markup, String courseId) {
  final files = <String, String>{};
  for (final tag in _markup.allMatches(markup)) {
    final attributes = tag[2];
    if (attributes == null) continue;
    final attrs = _htmlAttribute.allMatches(attributes).toList();
    final ids = attrs
        .map((attr) => _canvasFileLink(attr, courseId))
        .whereType<String>();
    if (ids.isEmpty) continue;
    final label = _assignmentFileLabel(markup, tag.end, attrs);
    for (final id in ids) {
      files.update(
        id,
        (old) => old.isEmpty ? label : old,
        ifAbsent: () => label,
      );
    }
  }
  return files;
}

String _assignmentFileLabel(
  String description,
  int start,
  List<RegExpMatch> attributes,
) {
  final end = description.length < start + 512
      ? description.length
      : start + 512;
  final tail = description.substring(start, end);
  final boundary = _anchorBoundary.firstMatch(tail);
  final names =
      [
            for (final attr in attributes)
              if (const {'title', 'download'}.contains(attr[1]?.toLowerCase()))
                attr[2] ?? attr[3] ?? attr[4] ?? '',
            if (boundary != null && boundary[1] != null)
              tail.substring(0, boundary.start),
          ]
          .map(plainText)
          .where(
            (name) => name.isNotEmpty && !agentUnsafeFileName.hasMatch(name),
          );
  return names.firstWhere(
    (name) => agentFileMimeType(null, [name]) != null,
    orElse: () => names.firstOrNull ?? '',
  );
}

// Ignore comments and raw script/style bodies when finding assignment links.
final _anchorBoundary = RegExp(r'(</a\s*>)|<a\s', caseSensitive: false);
final _markup = RegExp(
  r'''<!--[\s\S]*?(?:-->|$)|<(script|style)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)|<a\s+((?:"[^"]*"|'[^']*'|[^"'<>])*)>|</?[a-z][\w:-]*\b(?:"[^"]*"|'[^']*'|[^"'<>])*>''',
  caseSensitive: false,
);
final _htmlAttribute = RegExp(
  r'''([^\s"'=<>/`]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?''',
);
final _courseFilePath = RegExp(
  r'^/(?:api/v1/)?courses/([1-9][0-9]{0,23})/files/([1-9][0-9]{0,23})(?:/(?:download|preview))?/?$',
);
final _filePath = RegExp(
  r'^/(?:api/v1/)?files/([1-9][0-9]{0,23})(?:/(?:download|preview))?/?$',
);

String? _canvasFileLink(RegExpMatch attribute, String courseId) {
  if (!const {
    'href',
    'data-api-endpoint',
  }.contains(attribute[1]?.toLowerCase())) {
    return null;
  }
  final value = attribute[2] ?? attribute[3] ?? attribute[4];
  if (value == null || value.length > 8192) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.hasScheme && uri.scheme != 'https') ||
      (uri.hasAuthority &&
          (uri.host != _canvasHost ||
              uri.authority.contains('@') ||
              (uri.hasPort && uri.port != 443))) ||
      (uri.hasScheme && !uri.hasAuthority)) {
    return null;
  }
  final path = uri.path;
  if (_courseFilePath.firstMatch(path) case final match?) {
    return match[1] == courseId ? match[2] : null;
  }
  return _filePath.firstMatch(path)?[1];
}

String _canvasId(Object? value) {
  if (value is String && AgentCampusLink.isCanvasId(value)) return value;
  throw const AgentFailure('请使用 Canvas 列表返回的有效课程、作业和文件 ID。');
}

String? _optionalAssignmentId(Json args) =>
    args.containsKey('assignment_id') ? _canvasId(args['assignment_id']) : null;
