// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../../../agent/agent_session.dart';
import '../../../agent/agent_types.dart';
import '../campus_api.dart';
import '../learning/cloud/cloud_models.dart';

const _cloudSource = AgentSourceKind.cloudFiles;
const _maxCloudPathLength = 4096;
const _pathField = {'type': 'string', 'maxLength': _maxCloudPathLength};
const agentFileQueryField = {'type': 'string', 'maxLength': 120};
const agentFilePageField = {'type': 'integer', 'minimum': 1, 'maximum': 100000};
const agentFileReadTimeout = Duration(minutes: 6);
const _maxCloudRecords = 20;
const _maxCloudRecordChars = 10000;
const _maxCloudFolders = 8;
const _maxCloudDepth = 2;

Iterable<AgentTool> cloudFileAgentTools(CampusApi api) => [
  AgentTool(
    spec: const AgentToolSpec(
      'campus_cloud_roots',
      '列出复旦云盘的个人和群组根目录。知道目录标题时，可按关键词筛选。',
      {
        'type': 'object',
        'properties': {'query': agentFileQueryField},
        'required': [],
        'additionalProperties': false,
      },
    ),
    source: _cloudSource,
    label: '查询复旦云盘根目录',
    read: (args) => _cloudRoots(api, args),
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_cloud_list',
      '列出一个复旦云盘目录的直接子项。使用根目录或目录列表返回的 path，知道名称时请提供关键词。',
      {
        'type': 'object',
        'properties': {'path': _pathField, 'query': agentFileQueryField},
        'required': ['path'],
        'additionalProperties': false,
      },
    ),
    source: _cloudSource,
    label: '查询复旦云盘目录',
    read: (args) => _cloudFiles(api, args, maxDepth: 0),
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_cloud_search',
      '从指定复旦云盘目录开始，按名称关键词搜索文件和子目录，最多检查 8 个目录、向下 2 层。'
          '根据目录标题找到目标目录后，原样传入该目录返回的 path。',
      {
        'type': 'object',
        'properties': {'path': _pathField, 'query': agentFileQueryField},
        'required': ['path', 'query'],
        'additionalProperties': false,
      },
    ),
    source: _cloudSource,
    label: '搜索复旦云盘文件',
    read: (args) => _cloudFiles(api, args, maxDepth: _maxCloudDepth),
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_cloud_read',
      '读取一个复旦云盘文件。原样传入目录列表或搜索结果返回的文件 path。'
          'PDF 和 UTF-8 文本最大 200 MiB。可用 page 指定 PDF 页码，大 PDF 按页返回，长文本返回节选。支持小尺寸 PNG、JPEG 和 WebP。',
      {
        'type': 'object',
        'properties': {'path': _pathField, 'page': agentFilePageField},
        'required': ['path'],
        'additionalProperties': false,
      },
    ),
    source: _cloudSource,
    label: '读取复旦云盘文件',
    timeout: agentFileReadTimeout,
    read: (args) => readAgentRemoteFile(api, _cloudSource.label, {
      'source': 'cloud',
      'path': _cloudPath(args),
      'page': ?args['page'],
    }),
  ),
];

Future<Json> _cloudRoots(CampusApi api, Json args) async {
  final query = agentFileQuery(args);
  final result = await callAgentFileApi(api, 'fudan.cloud.roots');
  if (result is! List) throw const AgentFailure('无法读取复旦云盘根目录。');
  final records = _CloudRecords();
  for (final row in result.whereType<Json>()) {
    final root = CloudRoot.fromJson(row);
    if (root.path.isEmpty || !agentFileMatches(query, [root.name])) continue;
    if (!records.add({
      'name': agentFileLabel(root.name),
      'path': root.path,
      'kind': root.isGroup ? 'group' : 'personal',
      'is_folder': true,
    })) {
      break;
    }
  }
  return records.result;
}

Future<Json> _cloudFiles(
  CampusApi api,
  Json args, {
  required int maxDepth,
}) async {
  final path = _cloudPath(args);
  final query = agentFileQuery(args);
  if (maxDepth > 0 && query.isEmpty) throw const AgentFailure('请输入文件名关键词。');
  final records = _CloudRecords();
  final queued = Queue.of([(path: path, depth: 0)]);
  final seen = {path};
  while (queued.isNotEmpty) {
    final folder = queued.removeFirst();
    final result = await callAgentFileApi(api, 'fudan.cloud.list', {
      'path': folder.path,
    });
    if (result is! Json || result['items'] is! List) {
      throw const AgentFailure('无法读取复旦云盘目录。');
    }
    for (final item in cloudItemsOf(result)) {
      if (agentFileMatches(query, [item.name]) &&
          !records.add(_cloudRecord(item))) {
        return records.result;
      }
      if (!item.isFolder || maxDepth == 0 || seen.contains(item.path)) continue;
      if (folder.depth >= maxDepth || seen.length >= _maxCloudFolders) {
        records.truncated = true;
      } else {
        seen.add(item.path);
        queued.add((path: item.path, depth: folder.depth + 1));
      }
    }
  }
  return records.result;
}

Json _cloudRecord(CloudItem item) {
  final mime = item.isFolder
      ? null
      : agentFileMimeType(item.contentType, [item.name]);
  return {
    'name': agentFileLabel(item.name),
    'path': item.path,
    'is_folder': item.isFolder,
    if (!item.isFolder)
      'readable':
          item.downloadable &&
          mime != null &&
          agentFileSizeSupported(mime, item.size),
    'mime_type': ?mime,
    if (item.size case final int size when size >= 0) 'size': size,
  };
}

class _CloudRecords {
  final _rows = <Json>[];
  var _chars = 0;
  var truncated = false;

  bool add(Json row) {
    final length = jsonEncode(row).length + 1;
    if (_rows.length >= _maxCloudRecords ||
        _chars + length > _maxCloudRecordChars) {
      truncated = true;
      return false;
    }
    _rows.add(row);
    _chars += length;
    return true;
  }

  Json get result => {
    'source': _cloudSource.label,
    'records': _rows,
    'truncated': truncated,
  };
}

String _cloudPath(Json args) {
  if (args['path'] case final String path
      when path.trim().isNotEmpty && path.length <= _maxCloudPathLength) {
    // The bridge validates opaque handles. Preserve every character from Core.
    return path;
  }
  throw const AgentFailure('请传入复旦云盘列表返回的 path。');
}

String agentFileQuery(Json args) =>
    (args['query'] as String?)?.trim().toLowerCase() ?? '';

bool agentFileMatches(String query, Iterable<String> names) =>
    query.isEmpty || names.any((name) => name.toLowerCase().contains(query));

final agentUnsafeFileName = RegExp(r'[\p{Cc}\p{Cf}<>:"/\\|?*]', unicode: true);

String agentFileLabel(String name) {
  final clean = name.replaceAll(agentUnsafeFileName, '_').trim();
  return clean.isEmpty ? '文件' : String.fromCharCodes(clean.runes.take(120));
}

const _pdfMime = 'application/pdf';
const _mimeByExtension = {
  'pdf': _pdfMime,
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'jpe': 'image/jpeg',
  'webp': 'image/webp',
  'txt': 'text/plain',
  'text': 'text/plain',
  'log': 'text/plain',
  'md': 'text/markdown',
  'markdown': 'text/markdown',
  'mdown': 'text/markdown',
  'mkd': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
};

String? agentFileMimeType(String? reported, Iterable<String> names) {
  String? fromName(String value) {
    final dot = value.lastIndexOf('.');
    return dot < 0
        ? null
        : _mimeByExtension[value.substring(dot + 1).toLowerCase()];
  }

  final mime = reported?.split(';').first.trim().toLowerCase() ?? '';
  final inferred = names.map(fromName).whereType<String>().firstOrNull;
  final resolved = switch (mime) {
    '' ||
    'application/octet-stream' ||
    'binary/octet-stream' ||
    '*/*' => inferred,
    'text/plain' when agentTextAttachmentTypes.contains(inferred) => inferred,
    'image/jpg' || 'image/pjpeg' => 'image/jpeg',
    'text/x-markdown' => 'text/markdown',
    'application/csv' => 'text/csv',
    'text/json' => 'application/json',
    _ => mime,
  };
  if (resolved == null || !isAgentAttachmentType(resolved)) return null;
  if (inferred != null &&
      inferred != resolved &&
      !(agentTextAttachmentTypes.contains(inferred) &&
          agentTextAttachmentTypes.contains(resolved))) {
    return null;
  }
  return resolved;
}

bool agentFileSizeSupported(String mime, int? size) {
  if (size == null || size < 0) return true;
  final limit = switch (mime) {
    _pdfMime => agentMaxCampusFileBytes,
    _ when agentTextAttachmentTypes.contains(mime) => agentMaxCampusFileBytes,
    _ => agentMaxAttachmentBytes,
  };
  return size > 0 && size <= limit;
}

Future<Json> readAgentRemoteFile(
  CampusApi api,
  String source,
  Json params,
) async {
  final result = await callAgentFileApi(api, 'agent.remoteFile.read', params);
  try {
    if (result case {
      'name': final String name,
      'mime_type': final String mimeType,
      'data': final String data,
    }) {
      final file = AgentAttachment.fromHost(
        name: name,
        mimeType: mimeType,
        data: data,
        isCampusFile: true,
      );
      return {
        'source': source,
        if (params['source'] == 'canvas') ...{
          'course_id': params['course_id'],
          'file_id': params['file_id'],
          'assignment_id': ?params['assignment_id'],
        },
        'name': file.name,
        'mime_type': file.mimeType,
        'size': file.byteLength,
        if (result['page'] case final int page when page > 0) 'page': page,
        if (result['page_count'] case final int count when count > 0)
          'page_count': count,
        if (result['preview'] case final String kind
            when const {
              'page_text',
              'page_image',
              'text_excerpt',
            }.contains(kind))
          'preview': kind,
        if (result['extracted'] case final bool value) 'extracted': value,
        if (result['truncated'] case final bool value) 'truncated': value,
        'attachment': file,
      };
    }
  } on FormatException {
    throw const AgentFailure('无法读取文件，返回的文件数据无效。');
  }
  throw const AgentFailure('无法读取文件，返回的文件数据无效。');
}

Future<Object?> callAgentFileApi(
  CampusApi api,
  String method, [
  Json params = const {},
]) async {
  try {
    if (api.accountScope == null) {
      throw PlatformException(code: 'AccountRequired');
    }
    return await api.call(method, params);
  } on PlatformException catch (error) {
    throw AgentFailure(switch (error.code) {
      'AssetTooLarge' || 'ResponseTooLarge' => '文件超过 200 MiB 下载上限。',
      'InvalidPage' => '指定的页码超出 PDF 范围。',
      'PdfPreviewUnavailable' => '无法读取此 PDF 的指定页。请尝试其他页或在校园文件查看器中打开。',
      'AttachmentTooLarge' => '原始附件不能超过 2 MiB。',
      'AttachmentTextTooLarge' => '文本附件不能超过 24 KiB。',
      'AttachmentUnsupportedType' => '请使用 PDF、PNG、JPEG、WebP 或 UTF-8 文本文件。',
      'AttachmentInvalidContent' => '文件内容无效或与文件类型不匹配。',
      'AssetBusy' => '文件正在使用，请稍后重试。',
      'AssetMissing' || 'NotFound' || 'FileUnavailable' => '文件暂时无法读取，请重新查询。',
      _ => campusError(error),
    });
  } on FormatException {
    throw const AgentFailure('校园服务返回的文件数据格式无效。');
  }
}
