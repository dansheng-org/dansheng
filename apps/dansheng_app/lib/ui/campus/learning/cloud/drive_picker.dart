// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../campus_api.dart';
import '../../campus_account_boundary.dart';
import '../widgets/learning_common.dart';
import 'cloud_drive_page.dart';
import 'drive_backend.dart';

/// Lists every drive: the Fudan cloud drive and configured WebDAV servers.
/// With [pickTitle] set, choosing a drive opens it as a folder picker and the
/// page returns the chosen [DriveTarget].
class DriveHubPage extends StatefulWidget {
  final CampusApi api;
  final String? pickTitle;

  const DriveHubPage({super.key, required this.api, this.pickTitle});

  @override
  State<DriveHubPage> createState() => _DriveHubPageState();
}

class _DriveHubPageState extends State<DriveHubPage> {
  List<DriveBackend>? _drives;
  String? _error;

  bool get _picking => widget.pickTitle != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final drives = await availableDrives(widget.api);
      if (mounted) setState(() => _drives = drives);
    } catch (error) {
      if (mounted) setState(() => _error = campusError(error));
    }
  }

  Future<void> _open(DriveBackend drive) async {
    final target = await Navigator.of(context).push<DriveTarget>(
      MaterialPageRoute(
        builder: (_) => CloudDrivePage(drive: drive, pickFolder: _picking),
      ),
    );
    if (!mounted) return;
    if (_picking && target != null) {
      Navigator.of(context).pop(target);
    } else {
      _load();
    }
  }

  Future<void> _addServer() async {
    final entered = await showDialog<(String, String)>(
      context: context,
      builder: (_) =>
          CampusAccountBoundary(api: widget.api, child: const _ServerDialog()),
    );
    if (entered == null || !mounted) return;
    final (nameText, urlText) = entered;
    try {
      final server = await widget.api.call('webdav.server.add', {
        'url': urlText,
        if (nameText.isNotEmpty) 'name': nameText,
      });
      final id = server is Map ? server['id']?.toString() : null;
      if (id != null) {
        // The native sheet asks for the username and password.
        await widget.api.call('campus.login', {'service': 'webdav:$id'});
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.toString().contains('InvalidConfiguration')
                  ? '地址无效：请填写完整的 HTTPS WebDAV 地址'
                  : campusError(error),
            ),
          ),
        );
      }
    }
    _load();
  }

  Future<void> _remove(WebDavBackend drive) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => CampusAccountBoundary(
        api: widget.api,
        child: AlertDialog(
          title: const Text('移除 WebDAV'),
          content: Text('移除「${drive.title}」并清除本机保存的登录信息？云端文件不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('移除'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.call('webdav.server.remove', {'id': drive.server.id});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(error))));
      }
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final drives = _drives;
    return CampusAccountBoundary(
      api: widget.api,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.pickTitle ?? '云盘',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (_error != null)
              InfoBanner(message: _error!, actionLabel: '重试', onAction: _load),
            if (drives == null)
              const SectionSpinner()
            else
              for (final drive in drives)
                Card(
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Icon(
                      drive is FudanCloudBackend
                          ? Icons.cloud_rounded
                          : Icons.dns_outlined,
                      color: scheme.primary,
                    ),
                    title: Text(drive.title),
                    subtitle: Text(
                      drive is WebDavBackend
                          ? '${Uri.tryParse(drive.server.url)?.host ?? drive.server.url}'
                                '${drive.server.connected ? '' : ' · 未登录'}'
                          : 'cloud.fudan.edu.cn',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: drive is WebDavBackend && !_picking
                        ? IconButton(
                            tooltip: '移除',
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () => _remove(drive),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(drive),
                  ),
                ),
            if (!_picking) ...[
              const SizedBox(height: 4),
              OutlinedButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加 WebDAV 云盘'),
                onPressed: _addServer,
              ),
              const SizedBox(height: 8),
              Text(
                '支持 Nextcloud、坚果云等提供 HTTPS WebDAV 的网盘。局域网 NAS 暂不支持。',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lets the person choose a drive and a folder; null when cancelled.
Future<DriveTarget?> pickDriveFolder(
  BuildContext context,
  CampusApi api, {
  String title = '保存到',
}) => Navigator.of(context).push<DriveTarget>(
  MaterialPageRoute(
    builder: (_) => DriveHubPage(api: api, pickTitle: title),
  ),
);

/// Picks a folder and uploads a downloaded file (asset) into it, reporting
/// the outcome with a snack bar.
Future<void> saveAssetToDrive(
  BuildContext context,
  CampusApi api, {
  required Future<String> Function() assetId,
  required String name,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final target = await pickDriveFolder(context, api, title: '保存「$name」到');
  if (target == null) return;
  messenger.showSnackBar(SnackBar(content: Text('正在保存到 ${target.label}…')));
  try {
    api.accountScope?.check();
    final id = await assetId();
    api.accountScope?.check();
    await target.drive.uploadAsset(target.folder, id, name: name);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('已保存到 ${target.label}')));
  } catch (error) {
    final text = error.toString();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          text.contains('LocalUploadTooLarge')
              ? '本地文件超过 5 MiB，暂不支持上传'
              : text.contains('AssetTooLarge')
              ? '文件超过 8 MB，暂不支持上传'
              : text.contains('AuthenticationRequired')
              ? '请先在「云盘」中登录 ${target.drive.title}'
              : campusError(error),
        ),
      ),
    );
  }
}

/// Asks for a WebDAV server's name and address (never its credentials).
class _ServerDialog extends StatefulWidget {
  const _ServerDialog();

  @override
  State<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends State<_ServerDialog> {
  final _name = TextEditingController();
  final _url = TextEditingController(text: 'https://');

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('添加 WebDAV'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: '名称（可选）',
            hintText: '例如：坚果云',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'WebDAV 地址',
            hintText: 'https://dav.jianguoyun.com/dav/',
            helperText: '仅支持 HTTPS；用户名和密码在下一步安全输入',
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.of(context).pop((_name.text.trim(), _url.text.trim())),
        child: const Text('下一步'),
      ),
    ],
  );
}
