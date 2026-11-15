// SPDX-License-Identifier: GPL-3.0-or-later
import '../models/canvas_learning_models.dart'
    show formatCampusTime, parseInt, parseTime;

/// A top-level drive folder: personal files or one group's files.
class CloudRoot {
  final String kind;
  final String name;
  final String path;

  const CloudRoot({required this.kind, required this.name, required this.path});

  factory CloudRoot.fromJson(Map<String, dynamic> json) => CloudRoot(
    kind: json['kind']?.toString() ?? 'personal',
    name: json['name']?.toString() ?? '个人文件',
    path: json['path']?.toString() ?? '',
  );

  bool get isGroup => kind == 'group';
}

/// One file or folder of a drive listing. [path] is an opaque handle that is
/// only passed back to the host.
class CloudItem {
  final String name;
  final String path;
  final bool isFolder;
  final int? size;
  final DateTime? modifiedAt;
  final String? contentType;
  final int? children;
  final bool downloadable;
  final bool canRename;
  final bool canDelete;
  final bool canShare;

  const CloudItem({
    required this.name,
    required this.path,
    required this.isFolder,
    this.size,
    this.modifiedAt,
    this.contentType,
    this.children,
    this.downloadable = false,
    this.canRename = true,
    this.canDelete = true,
    this.canShare = false,
  });

  factory CloudItem.fromJson(Map<String, dynamic> json) => CloudItem(
    name: json['name']?.toString() ?? '',
    path: json['path']?.toString() ?? '',
    isFolder: json['is_folder'] == true,
    size: parseInt(json['size']),
    modifiedAt: parseTime(json['modified_at']),
    contentType: json['content_type']?.toString(),
    children: parseInt(json['children']),
    // WebDAV listings carry no rights; the server enforces them.
    downloadable: json['downloadable'] as bool? ?? json['is_folder'] != true,
    canRename: json['can_rename'] as bool? ?? true,
    canDelete: json['can_delete'] as bool? ?? true,
    canShare: json['can_share'] == true,
  );

  String get sizeFormatted {
    final bytes = size;
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get subtitle => [
    if (isFolder && children != null) '$children 项',
    if (!isFolder && sizeFormatted.isNotEmpty) sizeFormatted,
    if (modifiedAt != null) formatCampusTime(modifiedAt),
  ].join(' · ');

  /// Fields the host uses to key its local copy of this file.
  Map<String, dynamic> get downloadParams => {
    'path': path,
    if (size != null) 'size': size,
    if (modifiedAt != null)
      'modified_at': modifiedAt!.toUtc().toIso8601String(),
    if (contentType != null) 'content_type': contentType,
  };
}

/// The rows of a `fudan.cloud.list` response.
List<CloudItem> cloudItemsOf(dynamic listing) {
  final items = listing is Map ? listing['items'] : null;
  if (items is! List) return const [];
  return [
    for (final row in items.whereType<Map<String, dynamic>>())
      if ((row['name']?.toString() ?? '').isNotEmpty &&
          (row['path']?.toString() ?? '').isNotEmpty)
        CloudItem.fromJson(row),
  ];
}

/// One folder's contents and whether new entries may be created in it.
class CloudListing {
  final List<CloudItem> items;
  final bool canCreate;
  const CloudListing(this.items, {this.canCreate = true});

  factory CloudListing.fromJson(dynamic json) => CloudListing(
    cloudItemsOf(json),
    canCreate: json is Map ? json['can_create'] != false : true,
  );
}
