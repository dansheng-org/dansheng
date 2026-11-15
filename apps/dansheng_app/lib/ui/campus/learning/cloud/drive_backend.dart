// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

import '../../campus_api.dart';
import 'cloud_models.dart';

/// A created share link; [fetchCode] is the link password when present.
class DriveShare {
  final String url;
  final String batchLink;
  final String? fetchCode;
  const DriveShare(this.url, this.batchLink, this.fetchCode);
}

bool isAuthError(Object error) {
  final code = error is PlatformException ? error.code : error.toString();
  return code.contains('AuthenticationRequired') ||
      code.contains('InvalidCredentials');
}

/// One browsable drive. Every call goes through the native host; credentials
/// and file bytes never pass through Flutter.
abstract class DriveBackend {
  final CampusApi api;
  DriveBackend(this.api);

  String get title;

  /// A stable id, used to tell drives apart in pickers.
  String get key;

  /// Methods whose responses the host may keep as an offline copy.
  String get listMethod;
  String get rootsMethod;
  Map<String, dynamic> get scope;

  Future<List<CloudRoot>> roots();

  Map<String, dynamic> listParams(String path) => {...scope, 'path': path};

  CloudListing parseListing(dynamic value) => CloudListing.fromJson(value);

  /// Downloads into the managed file store; returns the asset id.
  Future<String> download(CloudItem item);
  Future<void> createFolder(String parent, String name);
  Future<void> rename(CloudItem item, String name);
  Future<void> delete(CloudItem item);

  /// Picks a local file on the device and uploads it into [folder].
  Future<void> uploadLocal(String folder);

  /// Uploads an already downloaded file (notice attachment, course file…).
  Future<void> uploadAsset(String folder, String assetId, {String? name});

  bool get canShare => false;
  Future<DriveShare> share(CloudItem item) =>
      throw PlatformException(code: 'CapabilityUnavailable');
  Future<void> revokeShare(String batchLink) async {}

  Future<void> signIn();

  Future<String> _asset(String method, Map<String, dynamic> params) async {
    final result = await api.call(method, params);
    final id = result is Map ? result['asset_id']?.toString() : null;
    if (id == null || id.isEmpty) {
      throw PlatformException(code: 'FileUnavailable');
    }
    return id;
  }
}

/// cloud.fudan.edu.cn (personal and group folders).
class FudanCloudBackend extends DriveBackend {
  FudanCloudBackend(super.api);

  @override
  String get title => '复旦云盘';
  @override
  String get key => 'fudan-cloud';
  @override
  String get listMethod => 'fudan.cloud.list';
  @override
  String get rootsMethod => 'fudan.cloud.roots';
  @override
  Map<String, dynamic> get scope => const {};

  @override
  Future<List<CloudRoot>> roots() async {
    final value = await api.call(rootsMethod);
    return [
      for (final row in (value as List).whereType<Map<String, dynamic>>())
        CloudRoot.fromJson(row),
    ].where((r) => r.path.isNotEmpty).toList();
  }

  @override
  Future<String> download(CloudItem item) =>
      _asset('fudan.cloud.download', item.downloadParams);

  @override
  Future<void> createFolder(String parent, String name) =>
      api.call('fudan.cloud.mkdir', {'path': parent, 'name': name});

  @override
  Future<void> rename(CloudItem item, String name) =>
      api.call('fudan.cloud.rename', {'path': item.path, 'name': name});

  @override
  Future<void> delete(CloudItem item) =>
      api.call('fudan.cloud.delete', {'path': item.path});

  @override
  Future<void> uploadLocal(String folder) => api.call(
    'campus.uploadLocalFile',
    {'target': 'fudan.cloud.upload', 'path': folder},
  );

  @override
  Future<void> uploadAsset(String folder, String assetId, {String? name}) =>
      api.call('fudan.cloud.upload', {
        'path': folder,
        'asset_id': assetId,
        'name': ?name,
      });

  @override
  bool get canShare => true;

  @override
  Future<DriveShare> share(CloudItem item) async {
    final result = await api.call('fudan.cloud.share', {
      'path': item.path,
      'days': 7,
      'with_code': true,
    });
    if (result is! Map || result['url'] == null) {
      throw PlatformException(code: 'SourceSchemaChanged');
    }
    return DriveShare(
      result['url'].toString(),
      result['batch_link']?.toString() ?? '',
      result['fetch_code']?.toString(),
    );
  }

  @override
  Future<void> revokeShare(String batchLink) =>
      api.call('fudan.cloud.unshare', {'batch_link': batchLink});

  @override
  Future<void> signIn() => api.call('campus.login', {'service': 'cloud'});
}

/// A configured WebDAV server.
class WebDavServer {
  final String id;
  final String name;
  final String url;
  final bool connected;
  const WebDavServer(this.id, this.name, this.url, this.connected);

  factory WebDavServer.fromJson(Map<String, dynamic> json) => WebDavServer(
    json['id']?.toString() ?? '',
    json['name']?.toString() ?? 'WebDAV',
    json['url']?.toString() ?? '',
    json['connected'] == true,
  );
}

class WebDavBackend extends DriveBackend {
  final WebDavServer server;
  WebDavBackend(super.api, this.server);

  @override
  String get title => server.name;
  @override
  String get key => 'webdav:${server.id}';
  @override
  String get listMethod => 'webdav.list';
  @override
  String get rootsMethod => 'webdav.list';
  @override
  Map<String, dynamic> get scope => {'id': server.id};

  @override
  Future<List<CloudRoot>> roots() async => [
    CloudRoot(kind: 'personal', name: server.name, path: '/'),
  ];

  @override
  Future<String> download(CloudItem item) => _asset('webdav.download', {
    ...scope,
    'path': item.path,
    'size': ?item.size,
    if (item.modifiedAt != null)
      'modified_at': item.modifiedAt!.toUtc().toIso8601String(),
  });

  @override
  Future<void> createFolder(String parent, String name) =>
      api.call('webdav.mkdir', {...scope, 'path': parent, 'name': name});

  @override
  Future<void> rename(CloudItem item, String name) => api.call(
    'webdav.rename',
    {...scope, 'path': item.path, 'name': name, 'is_folder': item.isFolder},
  );

  @override
  Future<void> delete(CloudItem item) => api.call('webdav.delete', {
    ...scope,
    'path': item.path,
    'is_folder': item.isFolder,
  });

  @override
  Future<void> uploadLocal(String folder) => api.call(
    'campus.uploadLocalFile',
    {'target': 'webdav.upload', 'id': server.id, 'path': folder},
  );

  @override
  Future<void> uploadAsset(String folder, String assetId, {String? name}) =>
      api.call('webdav.upload', {
        ...scope,
        'path': folder,
        'asset_id': assetId,
        'name': ?name,
      });

  @override
  Future<void> signIn() =>
      api.call('campus.login', {'service': 'webdav:${server.id}'});
}

/// Every drive available to the current account: the Fudan drive first.
Future<List<DriveBackend>> availableDrives(CampusApi api) async {
  final drives = <DriveBackend>[FudanCloudBackend(api)];
  try {
    final servers = await api.call('webdav.servers');
    if (servers is List) {
      drives.addAll([
        for (final row in servers.whereType<Map<String, dynamic>>())
          if ((row['id']?.toString() ?? '').isNotEmpty)
            WebDavBackend(api, WebDavServer.fromJson(row)),
      ]);
    }
  } catch (error) {
    if (isAccountChange(error)) rethrow;
  }
  return drives;
}
