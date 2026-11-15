// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../campus_account_boundary.dart';
import '../learning/cloud/drive_picker.dart';

/// One notice: its original page and its attachments, each of which can be
/// opened or saved into a cloud drive.
Future<void> showNoticeSheet(
  BuildContext context,
  CampusApi api, {
  required String title,
  required String url,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => CampusAccountBoundary(
    api: api,
    child: _NoticeSheet(api: api, title: title, url: url),
  ),
);

class _NoticeSheet extends StatefulWidget {
  final CampusApi api;
  final String title;
  final String url;
  const _NoticeSheet({
    required this.api,
    required this.title,
    required this.url,
  });

  @override
  State<_NoticeSheet> createState() => _NoticeSheetState();
}

class _NoticeSheetState extends State<_NoticeSheet> {
  late final Future<List<(String, String)>> _attachments = _load();
  final Set<String> _busy = {};

  Future<List<(String, String)>> _load() async {
    final value = await widget.api.call('fudan.notice.attachments', {
      'url': widget.url,
    });
    return [
      for (final row in (value is List ? value : const []).whereType<Map>())
        if (row['url'] is String)
          (row['name']?.toString() ?? '附件', row['url'] as String),
    ];
  }

  Future<String> _download(String name, String url) async {
    final result = await widget.api.call('fudan.notice.attachment.download', {
      'url': url,
      'name': name,
    });
    final id = result is Map ? result['asset_id']?.toString() : null;
    if (id == null) throw StateError('FileUnavailable');
    return id;
  }

  Future<void> _open(String name, String url) async {
    if (!_busy.add(url)) return;
    setState(() {});
    try {
      final id = await _download(name, url);
      await widget.api.call('campus.openFile', {'asset_id': id});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(url));
    }
  }

  Future<void> _openPage() async {
    try {
      await widget.api.call('campus.openNotice', {'url': widget.url});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('打开公告原文'),
              onPressed: _openPage,
            ),
            const SizedBox(height: 14),
            Text(
              '附件',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            FutureBuilder<List<(String, String)>>(
              future: _attachments,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  final auth = snapshot.error.toString().contains(
                    'AuthenticationRequired',
                  );
                  return Text(
                    auth
                        ? '这条公告需要在校园登录后查看，请打开原文'
                        : campusError(snapshot.error!),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  );
                }
                final files = snapshot.data ?? const [];
                if (files.isEmpty) {
                  return Text(
                    '这条公告没有附件',
                    style: TextStyle(fontSize: 13, color: scheme.outline),
                  );
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final (name, url) in files)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.attach_file_rounded),
                          title: Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _open(name, url),
                          trailing: _busy.contains(url)
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : IconButton(
                                  tooltip: '存到云盘',
                                  icon: const Icon(Icons.cloud_upload_outlined),
                                  onPressed: () => saveAssetToDrive(
                                    context,
                                    widget.api,
                                    assetId: () => _download(name, url),
                                    name: name,
                                  ),
                                ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
