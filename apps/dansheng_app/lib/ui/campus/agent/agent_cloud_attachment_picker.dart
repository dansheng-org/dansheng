// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../../agent/agent_campus_link.dart';
import '../../../agent/agent_types.dart';
import '../campus_api.dart';
import '../learning/cloud/cloud_models.dart';
import '../learning/models/canvas_models.dart';
import '../learning/widgets/learning_common.dart'
    show InfoBanner, SectionSpinner;
import 'agent_course_files.dart' show agentAssignmentFileLinks;
import 'agent_remote_files.dart';

/// Selects one original campus file. The caller owns the account scope.
class AgentCloudAttachmentPicker extends StatefulWidget {
  const AgentCloudAttachmentPicker({super.key, required this.api});

  final CampusApi api;

  @override
  State<AgentCloudAttachmentPicker> createState() =>
      _AgentCloudAttachmentPickerState();
}

class _AgentCloudAttachmentPickerState
    extends State<AgentCloudAttachmentPicker> {
  final _filter = TextEditingController();
  final _trail = <_Location>[];
  _File? _downloading;
  ({_File file, String message})? _downloadError;
  int _selection = 0;

  bool get _canBrowse =>
      widget.api.isCurrent &&
      widget.api.accountScope?.accountId?.isNotEmpty == true;

  @override
  void initState() {
    super.initState();
    _trail.add(_open(_sources));
  }

  @override
  void didUpdateWidget(AgentCloudAttachmentPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api)) {
      _resetSelection();
      _trail
        ..clear()
        ..add(_open(_sources));
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  _Location _open(_Folder folder) =>
      (folder: folder, listing: _load(folder, widget.api));

  void _resetSelection() {
    _selection++;
    _downloading = null;
    _downloadError = null;
    _filter.clear();
  }

  void _changeDirectory(VoidCallback change) {
    if (!_canBrowse) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _resetSelection();
      change();
    });
  }

  void _up() {
    if (_trail.length > 1) _changeDirectory(_trail.removeLast);
  }

  Future<void> _choose(_File file) async {
    if (!_canBrowse || _downloading != null) return;
    final api = widget.api;
    final selection = ++_selection;
    setState(() {
      _downloading = file;
      _downloadError = null;
    });
    try {
      final result = await readAgentRemoteFile(api, file.source, file.params);
      if (!mounted || selection != _selection || !api.isCurrent) return;
      final attachment = result['attachment'] as AgentAttachment;
      if (ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop<AgentAttachment>(attachment);
      } else {
        setState(() => _downloading = null);
      }
    } catch (error) {
      if (!mounted || selection != _selection || !api.isCurrent) return;
      setState(() {
        _downloading = null;
        _downloadError = (file: file, message: _errorMessage(error));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.api.accountScope;
    return scope == null
        ? _buildPage()
        : ListenableBuilder(listenable: scope, builder: (_, _) => _buildPage());
  }

  Widget _buildPage() {
    final canBrowse = _canBrowse;
    final atTop = !canBrowse || _trail.length == 1;
    final location = _trail.last;
    return PopScope<AgentAttachment>(
      canPop: atTop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !atTop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: atTop ? null : BackButton(onPressed: _up),
          title: Text(canBrowse ? location.folder.name : _sources.name),
        ),
        body: canBrowse
            ? _buildBrowser(location, atTop)
            : ModalRoute.of(context)?.isCurrent == false
            ? const SizedBox.shrink()
            : Center(
                child: Text(
                  widget.api.isCurrent ? '请先选择校园账号。' : '账号已变更，请返回后重新打开。',
                ),
              ),
      ),
    );
  }

  Widget _buildBrowser(_Location location, bool atTop) => SafeArea(
    child: Column(
      children: [
        if (!atTop)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: '筛选当前列表',
              ),
            ),
          ),
        if (_downloading case final file?) ...[
          const LinearProgressIndicator(),
          ListTile(title: Text('正在下载 ${file.name}…')),
        ],
        if (_downloadError case final error?)
          InfoBanner(
            message: error.message,
            actionLabel: '重试下载',
            onAction: () => _choose(error.file),
          ),
        Expanded(
          child: FutureBuilder(
            future: location.listing,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SectionSpinner();
              }
              final listing = snapshot.requireData;
              if (listing.error case final error?) {
                return Center(
                  child: InfoBanner(
                    message: error,
                    actionLabel: '重试',
                    onAction: () => _changeDirectory(
                      () => _trail[_trail.length - 1] = _open(location.folder),
                    ),
                  ),
                );
              }
              return _buildRows(listing.rows, location.folder);
            },
          ),
        ),
      ],
    ),
  );

  Widget _buildRows(List<_Entry> entries, _Folder folder) {
    final query = _filter.text.trim().toLowerCase();
    final shown = entries
        .where(
          (entry) => agentFileMatches(query, [
            entry.name,
            if (entry is _File) entry.filename,
          ]),
        )
        .toList();
    if (shown.isEmpty) {
      return Center(child: Text(query.isEmpty ? '这里没有可选项目' : '没有匹配的项目'));
    }
    return ListView.builder(
      key: ObjectKey(folder),
      itemCount: shown.length,
      itemBuilder: (context, index) {
        final entry = shown[index];
        final subtitle = entry is _File
            ? entry.unavailable ?? entry.subtitle
            : entry.subtitle;
        final enabled =
            _downloading == null &&
            switch (entry) {
              _Folder() => true,
              _File(:final unavailable) => unavailable == null,
            };
        return ListTile(
          enabled: enabled,
          leading: Icon(entry.icon),
          title: Text(entry.name),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: entry is _Folder ? const Icon(Icons.chevron_right) : null,
          onTap: !enabled
              ? null
              : switch (entry) {
                  _Folder() => () => _changeDirectory(
                    () => _trail.add(_open(entry)),
                  ),
                  _File() => () => _choose(entry),
                },
        );
      },
    );
  }
}

String _errorMessage(Object error) =>
    error is AgentFailure ? error.message : campusError(error);

typedef _Listing = ({List<_Entry> rows, String? error});
typedef _Location = ({_Folder folder, Future<_Listing> listing});

Future<_Listing> _load(_Folder folder, CampusApi api) async {
  try {
    return (rows: await folder.load(api), error: null);
  } catch (error) {
    return (rows: const <_Entry>[], error: _errorMessage(error));
  }
}

sealed class _Entry {
  const _Entry(this.name, this.icon, {this.subtitle});
  final String name;
  final IconData icon;
  final String? subtitle;
}

class _Folder extends _Entry {
  const _Folder(super.name, super.icon, this.load, {super.subtitle});
  final Future<List<_Entry>> Function(CampusApi) load;
}

class _File extends _Entry {
  _File(
    String name, {
    required this.filename,
    required this.source,
    required this.params,
    required String? mime,
    int? size,
    bool downloadable = true,
    bool allowUnknownType = false,
    String? details,
  }) : unavailable = !downloadable
           ? '当前无法下载'
           : mime == null && !allowUnknownType
           ? '暂不支持此文件类型'
           : mime != null && !agentFileSizeSupported(mime, size)
           ? '超出附件大小限制或文件为空'
           : null,
       super(
         name,
         mime == 'application/pdf'
             ? Icons.picture_as_pdf_outlined
             : Icons.insert_drive_file_outlined,
         subtitle: details,
       );

  final String filename;
  final String source;
  final Json params;
  final String? unavailable;
}

final _sources = _Folder(
  '附加云端文件',
  Icons.cloud_outlined,
  (_) async => const [
    _Folder('eLearning', Icons.school_outlined, _courses),
    _Folder('复旦云盘', Icons.cloud_outlined, _cloudRoots),
  ],
);

Future<List<Json>> _rows(
  CampusApi api,
  String method, [
  Json params = const {},
]) async {
  final response = await callAgentFileApi(api, method, params);
  if (response is! List) throw const AgentFailure('无法读取列表，请重试。');
  return rowsOf(response);
}

Future<List<_Entry>> _courses(CampusApi api) async => [
  for (final course in (await _rows(
    api,
    'canvas.courses.sync',
  )).map(CanvasCourse.fromJson))
    if (AgentCampusLink.isCanvasId(course.id))
      _Folder(
        course.name,
        Icons.folder_outlined,
        (_) async => [
          _Folder(
            '课程文件',
            Icons.folder_outlined,
            (api) => _materials(api, course.id),
          ),
          _Folder(
            '作业附件',
            Icons.assignment_outlined,
            (api) => _assignments(api, course.id),
          ),
        ],
        subtitle: course.termName ?? course.courseCode,
      ),
];

Future<List<_Entry>> _materials(CampusApi api, String courseId) async => [
  for (final row in await _rows(api, 'canvas.materials.sync', {
    'course_id': courseId,
  }))
    if (CanvasMaterial.fromJson(row, courseId) case final file
        when AgentCampusLink.isCanvasId(file.id) &&
            file.courseId == courseId &&
            !file.lockedForUser &&
            payloadOf(row)['hidden_for_user'] != true)
      _File(
        file.displayName,
        filename: file.filename,
        source: 'eLearning',
        params: {'source': 'canvas', 'course_id': courseId, 'file_id': file.id},
        mime: agentFileMimeType(file.contentType, [
          file.filename,
          file.displayName,
        ]),
        size: file.size,
        details: file.sizeFormatted.isEmpty ? null : file.sizeFormatted,
      ),
];

Future<List<_Entry>> _assignments(CampusApi api, String courseId) async {
  final assignments = <_Entry>[];
  for (final row in await _rows(api, 'canvas.assignments.sync', {
    'course_id': courseId,
  })) {
    final assignment = CanvasAssignment.fromJson(row, courseId);
    if (assignment.courseId != courseId ||
        !AgentCampusLink.isCanvasId(assignment.id) ||
        assignment.lockedForUser ||
        payloadOf(row)['published'] == false) {
      continue;
    }
    final links = agentAssignmentFileLinks(
      assignment.description ?? '',
      courseId,
    );
    if (links.isNotEmpty) {
      assignments.add(
        _Folder(
          assignment.name,
          Icons.assignment_outlined,
          (_) async => [
            for (final MapEntry(key: id, value: name) in links.entries)
              _File(
                name.isEmpty ? '作业文件 $id' : agentFileLabel(name),
                filename: name,
                source: 'eLearning',
                params: {
                  'source': 'canvas',
                  'course_id': courseId,
                  'file_id': id,
                  'assignment_id': assignment.id,
                },
                mime: agentFileMimeType(null, [name]),
                allowUnknownType: true,
              ),
          ],
        ),
      );
    }
  }
  return assignments;
}

Future<List<_Entry>> _cloudRoots(CampusApi api) async => [
  for (final root in (await _rows(
    api,
    'fudan.cloud.roots',
  )).map(CloudRoot.fromJson))
    if (root.path.isNotEmpty)
      _Folder(
        root.name,
        root.isGroup ? Icons.group_outlined : Icons.folder_outlined,
        (api) => _cloudDirectory(api, root.path),
        subtitle: root.isGroup ? '群组文件' : '个人文件',
      ),
];

Future<List<_Entry>> _cloudDirectory(CampusApi api, String path) async {
  final result = await callAgentFileApi(api, 'fudan.cloud.list', {
    'path': path,
  });
  if (result is! Json || result['items'] is! List) {
    throw const AgentFailure('无法读取复旦云盘目录，请重试。');
  }
  return [
    for (final item in cloudItemsOf(result))
      if (item.isFolder)
        _Folder(
          item.name,
          Icons.folder_outlined,
          (api) => _cloudDirectory(api, item.path),
        )
      else
        _File(
          item.name,
          filename: item.name,
          source: '复旦云盘',
          params: {'source': 'cloud', 'path': item.path},
          mime: agentFileMimeType(item.contentType, [item.name]),
          downloadable: item.downloadable,
          size: item.size,
          details: item.sizeFormatted.isEmpty ? null : item.sizeFormatted,
        ),
  ];
}
