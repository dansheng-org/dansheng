// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../agent/agent_campus_link.dart';
import '../../../agent/agent_session.dart';
import '../../../agent/agent_types.dart';
import '../campus_api.dart';
import '../learning/models/canvas_models.dart';

const _source = 'Canvas 课程文件';
const _pdfMime = 'application/pdf';
const _canvasHost = 'elearning.fudan.edu.cn';
const _idField = {'type': 'string', 'maxLength': 24};
const _pdfHeader = [0x25, 0x50, 0x44, 0x46, 0x2d];
final _unsafeName = RegExp(r'[\p{Cc}\p{Cf}<>:"/\\|?*]', unicode: true);

Iterable<AgentTool> courseFileAgentTools(CampusApi api) => [
  AgentTool(
    spec: const AgentToolSpec(
      'campus_course_files',
      '按 Canvas 课程 ID 列出可读取的 PDF。提供作业 ID 时，只列出该作业说明中的课程文件链接所指向的 PDF。',
      {
        'type': 'object',
        'properties': {'course_id': _idField, 'assignment_id': _idField},
        'required': ['course_id'],
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.files,
    label: '查询 Canvas 课程 PDF',
    read: (args) => _listCourseFiles(api, args),
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_read_course_pdf',
      '读取 Canvas 课程文件列表返回的 PDF，最大 2 MiB。请提供同一课程的课程 ID 和文件 ID。',
      {
        'type': 'object',
        'properties': {'course_id': _idField, 'file_id': _idField},
        'required': ['course_id', 'file_id'],
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.files,
    label: '读取 Canvas 课程 PDF',
    read: (args) => _readCoursePdf(api, args),
  ),
];

Future<int> clearAgentCourseFiles(CampusApi api) async {
  final result = await _call(api, 'agent.courseFile.clear');
  if (result case {'deleted': final int deleted} when deleted >= 0) {
    return deleted;
  }
  throw const AgentFailure('无法确认已清理的课程文件数量。');
}

Future<Json> _listCourseFiles(CampusApi api, Json args) async {
  final courseId = _canvasId(args['course_id']);
  final assignmentId = args.containsKey('assignment_id')
      ? _canvasId(args['assignment_id'])
      : null;
  final params = {'course_id': courseId};
  final linkedIds = assignmentId == null
      ? null
      : await _assignmentFileIds(api, courseId, assignmentId, params);
  final records = <Json>[];
  const limit = 25;
  var truncated = false;
  if (linkedIds == null || linkedIds.isNotEmpty) {
    final result = await _call(api, 'canvas.materials.sync', params);
    if (result is! List) {
      throw const AgentFailure('无法读取这门课程的文件列表。');
    }
    for (final row in rowsOf(result)) {
      final file = CanvasMaterial.fromJson(row, courseId);
      final size = file.size;
      if (file.courseId != courseId ||
          !AgentCampusLink.isCanvasId(file.id) ||
          (linkedIds != null && !linkedIds.contains(file.id)) ||
          file.lockedForUser ||
          payloadOf(row)['hidden_for_user'] == true ||
          size == null ||
          size < _pdfHeader.length ||
          size > agentMaxAttachmentBytes ||
          !_isPdf(file)) {
        continue;
      }
      if (records.length == limit) {
        truncated = true;
        break;
      }
      records.add({
        'file_id': file.id,
        'name': _fileLabel(file.displayName),
        'mime_type': _pdfMime,
        'size': size,
      });
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

Future<Json> _readCoursePdf(CampusApi api, Json args) async {
  final courseId = _canvasId(args['course_id']);
  final fileId = _canvasId(args['file_id']);
  final result = await _call(api, 'agent.courseFile.read', {
    'course_id': courseId,
    'file_id': fileId,
  });
  if (result
      case {
        'name': final String name,
        'mime_type': _pdfMime,
        'data': final String data,
      }
      when name.length <= 120 &&
          name.trim() == name &&
          name.toLowerCase().endsWith('.pdf') &&
          !_unsafeName.hasMatch(name)) {
    if (data.length > ((agentMaxAttachmentBytes + 2) ~/ 3) * 4) {
      throw const AgentFailure('课程 PDF 不能超过 2 MiB。');
    }
    try {
      final bytes = base64Decode(data);
      if (bytes.length > agentMaxAttachmentBytes) {
        throw const AgentFailure('课程 PDF 不能超过 2 MiB。');
      }
      if (bytes.length >= _pdfHeader.length &&
          _pdfHeader.indexed.every((entry) => bytes[entry.$1] == entry.$2)) {
        return {
          'source': _source,
          'course_id': courseId,
          'file_id': fileId,
          'name': name,
          'mime_type': _pdfMime,
          'size': bytes.length,
          'attachment': AgentAttachment(
            name: name,
            mimeType: _pdfMime,
            base64Data: data,
          ),
        };
      }
    } on FormatException {
      throw const AgentFailure('无法读取课程 PDF，返回的文件数据无效。');
    }
  }
  throw const AgentFailure('无法读取课程 PDF，返回的文件数据无效。');
}

Future<Set<String>> _assignmentFileIds(
  CampusApi api,
  String courseId,
  String assignmentId,
  Json params,
) async {
  final result = await _call(api, 'canvas.assignments.sync', params);
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
    final description = assignment.description ?? '';
    return {
      for (final tag in _markup.allMatches(description))
        if (tag[2] case final String attributes)
          for (final attr in _htmlAttribute.allMatches(attributes))
            if (_canvasFileLink(attr, courseId) case final String id) id,
    };
  }
  throw const AgentFailure('这门课程中没有找到可查看的指定作业。');
}

// Ignore comments and raw script/style bodies when finding assignment links.
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

bool _isPdf(CanvasMaterial file) {
  final mime = file.contentType?.split(';').first.trim().toLowerCase() ?? '';
  if (mime == _pdfMime) return true;
  const genericTypes = {
    '',
    'application/octet-stream',
    'binary/octet-stream',
    '*/*',
  };
  final filename = file.filename.isEmpty ? file.displayName : file.filename;
  return genericTypes.contains(mime) && filename.toLowerCase().endsWith('.pdf');
}

String _fileLabel(String name) {
  final clean = name.replaceAll(_unsafeName, '_').trim();
  return clean.isEmpty ? '课程文件' : String.fromCharCodes(clean.runes.take(120));
}

String _canvasId(Object? value) {
  if (value is String && AgentCampusLink.isCanvasId(value)) return value;
  throw const AgentFailure('请使用 Canvas 列表返回的有效课程、作业和文件 ID。');
}

Future<Object?> _call(
  CampusApi api,
  String method, [
  Json params = const {},
]) async {
  try {
    final scope = api.accountScope;
    if (scope == null) throw PlatformException(code: 'AccountRequired');
    scope.check();
    return await api.call(method, params);
  } on PlatformException catch (error) {
    throw AgentFailure(switch (error.code) {
      'AttachmentTooLarge' => '课程 PDF 不能超过 2 MiB。',
      'AttachmentUnsupportedType' => '只能读取 Canvas 课程 PDF。',
      'AttachmentInvalidContent' => '课程 PDF 的内容无效或大小未知。',
      'AssetBusy' => '课程文件正在使用，请稍后重试。',
      'AssetMissing' || 'NotFound' => '课程文件缓存已失效，请重新读取。',
      _ => campusError(error),
    });
  }
}
