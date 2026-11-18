// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-style forum data models for Dansheng.
// Floor fields adapted from DanXi lib/model/forum/floor.dart.
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.

/// Helper to unpack a list from either a direct List or a SourceBatch map.
List<Map<String, dynamic>> forumRowsOf(dynamic res) {
  if (res is List) {
    return res.whereType<Map<String, dynamic>>().toList();
  }
  if (res is Map) {
    if (res['records'] is List) {
      final list = <Map<String, dynamic>>[];
      for (final item in res['records'] as List) {
        if (item is Map) {
          final payload = item['payload'];
          if (payload is Map<String, dynamic>) {
            list.add(payload);
          } else if (item is Map<String, dynamic>) {
            list.add(item);
          }
        }
      }
      return list;
    }
    if (res['items'] is List) {
      return (res['items'] as List).whereType<Map<String, dynamic>>().toList();
    }
    if (res['results'] is List) {
      return (res['results'] as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    }
  }
  return <Map<String, dynamic>>[];
}

/// Star-prefixed tags mark folded threads and are hidden from tag chips.
bool isHiddenForumTag(String tag) => tag.startsWith('*');

bool isVisibleForumTag(String tag) => tag != '默认' && !isHiddenForumTag(tag);

/// Sort order for community holes.
enum ForumSortOrder {
  lastReplied('updated', '最新回复'),
  lastCreated('created', '最新发布');

  final String value;
  final String label;
  const ForumSortOrder(this.value, this.label);
}

/// Represents a single floor (comment or original post) in a hole.
class TeaFloor {
  final int floorId;
  final int holeId;
  final String? content;
  final String? anonyname;
  final String? timeCreated;
  final String? timeUpdated;
  final bool deleted;
  final int modified;
  final int like;
  final int dislike;
  final List<String> fold;
  final int? ranking;
  final int? replyTo;
  final String? specialTag;

  /// Written by the signed-in forum account; only such floors can be edited or deleted.
  final bool isMe;

  const TeaFloor({
    required this.floorId,
    required this.holeId,
    this.content,
    this.anonyname,
    this.timeCreated,
    this.timeUpdated,
    this.deleted = false,
    this.modified = 0,
    this.like = 0,
    this.dislike = 0,
    this.fold = const [],
    this.ranking,
    this.replyTo,
    this.specialTag,
    this.isMe = false,
  });

  factory TeaFloor.fromJson(Map<String, dynamic> json) {
    final rawFold = json['fold'];
    final List<String> parsedFold = [];
    if (rawFold is List) {
      for (final f in rawFold) {
        if (f != null && f.toString().isNotEmpty) {
          parsedFold.add(f.toString());
        }
      }
    }

    return TeaFloor(
      floorId: _parseInt(json['floor_id']),
      holeId: _parseInt(json['hole_id']),
      content: json['content']?.toString(),
      anonyname: json['anonyname']?.toString(),
      timeCreated: json['time_created']?.toString(),
      timeUpdated: json['time_updated']?.toString(),
      deleted: json['deleted'] == true,
      modified: _parseInt(json['modified']),
      like: _parseInt(json['like']),
      dislike: _parseInt(json['dislike']),
      fold: parsedFold,
      ranking: _parseOptionalInt(json['ranking']),
      replyTo: _parseOptionalInt(json['reply_to']),
      specialTag: json['special_tag']?.toString(),
      isMe: json['is_me'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'floor_id': floorId,
    'hole_id': holeId,
    'content': content,
    'anonyname': anonyname,
    'time_created': timeCreated,
    'time_updated': timeUpdated,
    'deleted': deleted,
    'modified': modified,
    'like': like,
    'dislike': dislike,
    'fold': fold,
    'ranking': ranking,
    'reply_to': replyTo,
    'special_tag': specialTag,
    'is_me': isMe,
  };
}

/// Preview of first and last floor on a hole.
class TeaFloorPreview {
  final TeaFloor? firstFloor;
  final TeaFloor? lastFloor;

  const TeaFloorPreview({this.firstFloor, this.lastFloor});

  factory TeaFloorPreview.fromJson(Map<String, dynamic> json) {
    return TeaFloorPreview(
      firstFloor: json['first_floor'] is Map<String, dynamic>
          ? TeaFloor.fromJson(json['first_floor'] as Map<String, dynamic>)
          : null,
      lastFloor: json['last_floor'] is Map<String, dynamic>
          ? TeaFloor.fromJson(json['last_floor'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'first_floor': firstFloor?.toJson(),
    'last_floor': lastFloor?.toJson(),
  };
}

/// Represents a hole (thread) in the forum.
class TeaHole {
  final int holeId;
  final int divisionId;
  final String? timeCreated;
  final String? timeUpdated;
  final String? timeDeleted;
  final int view;
  final int reply;
  final TeaFloorPreview? floors;
  final List<String> tags;
  final bool hidden;
  final bool locked;
  final bool frozen;

  const TeaHole({
    required this.holeId,
    required this.divisionId,
    this.timeCreated,
    this.timeUpdated,
    this.timeDeleted,
    this.view = 0,
    this.reply = 0,
    this.floors,
    this.tags = const [],
    this.hidden = false,
    this.locked = false,
    this.frozen = false,
  });

  factory TeaHole.fromJson(Map<String, dynamic> json) {
    TeaFloorPreview? floorsPreview;
    if (json['floors'] is Map<String, dynamic>) {
      floorsPreview = TeaFloorPreview.fromJson(
        json['floors'] as Map<String, dynamic>,
      );
    } else if (json['first_floor'] is Map<String, dynamic>) {
      floorsPreview = TeaFloorPreview(
        firstFloor: TeaFloor.fromJson(
          json['first_floor'] as Map<String, dynamic>,
        ),
        lastFloor: json['last_floor'] is Map<String, dynamic>
            ? TeaFloor.fromJson(json['last_floor'] as Map<String, dynamic>)
            : null,
      );
    }

    final rawTags = json['tags'];
    final List<String> parsedTags = [];
    if (rawTags is List) {
      for (final t in rawTags) {
        if (t is String && t.isNotEmpty) {
          parsedTags.add(t);
        } else if (t is Map && t['name'] != null) {
          parsedTags.add(t['name'].toString());
        }
      }
    }

    return TeaHole(
      holeId: _parseInt(json['hole_id']),
      divisionId: _parseInt(json['division_id']),
      timeCreated: json['time_created']?.toString(),
      timeUpdated: json['time_updated']?.toString(),
      timeDeleted: json['time_deleted']?.toString(),
      view: _parseInt(json['view']),
      reply: _parseInt(json['reply']),
      floors: floorsPreview,
      tags: parsedTags,
      hidden: json['hidden'] == true,
      locked: json['locked'] == true,
      frozen: json['frozen'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'hole_id': holeId,
    'division_id': divisionId,
    'time_created': timeCreated,
    'time_updated': timeUpdated,
    'time_deleted': timeDeleted,
    'view': view,
    'reply': reply,
    'floors': floors?.toJson(),
    'tags': tags,
    'hidden': hidden,
    'locked': locked,
    'frozen': frozen,
  };
}

/// Represents a division (category / board) in the forum.
class TeaDivision {
  final int divisionId;
  final String name;
  final String? description;
  final List<TeaHole> pinned;

  const TeaDivision({
    required this.divisionId,
    required this.name,
    this.description,
    this.pinned = const [],
  });

  factory TeaDivision.fromJson(Map<String, dynamic> json) {
    final rawPinned = json['pinned'];
    final List<TeaHole> parsedPinned = [];
    if (rawPinned is List) {
      for (final item in rawPinned) {
        if (item is Map<String, dynamic>) {
          parsedPinned.add(TeaHole.fromJson(item));
        }
      }
    }

    return TeaDivision(
      divisionId: _parseInt(json['division_id']),
      name: json['name']?.toString() ?? '分区',
      description: json['description']?.toString(),
      pinned: parsedPinned,
    );
  }

  Map<String, dynamic> toJson() => {
    'division_id': divisionId,
    'name': name,
    'description': description,
    'pinned': pinned.map((h) => h.toJson()).toList(),
  };
}

/// Search result model.
class ForumSearchResult {
  final int holeId;
  final int? floorId;
  final String content;
  final String? anonyname;
  final String? timeCreated;
  final List<String> tags;
  final bool deleted;
  final List<String> fold;
  final int? ranking;
  final int? replyTo;
  final String? specialTag;

  const ForumSearchResult({
    required this.holeId,
    this.floorId,
    required this.content,
    this.anonyname,
    this.timeCreated,
    this.tags = const [],
    this.deleted = false,
    this.fold = const [],
    this.ranking,
    this.replyTo,
    this.specialTag,
  });

  factory ForumSearchResult.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final List<String> parsedTags = [];
    if (rawTags is List) {
      for (final t in rawTags) {
        if (t is String && t.isNotEmpty) {
          parsedTags.add(t);
        } else if (t is Map && t['name'] != null) {
          parsedTags.add(t['name'].toString());
        }
      }
    }

    final rawContent =
        json['content']?.toString() ?? json['text']?.toString() ?? '';
    final isDeleted = json['deleted'] == true;
    final fold = json['fold'] is List
        ? (json['fold'] as List)
              .where((value) => value != null && value.toString().isNotEmpty)
              .map((value) => value.toString())
              .toList()
        : <String>[];

    return ForumSearchResult(
      holeId: _parseInt(json['hole_id']),
      floorId: json['floor_id'] != null ? _parseInt(json['floor_id']) : null,
      content: rawContent,
      anonyname: json['anonyname']?.toString(),
      timeCreated: json['time_created']?.toString(),
      tags: parsedTags,
      deleted: isDeleted,
      fold: fold,
      ranking: _parseOptionalInt(json['ranking']),
      replyTo: _parseOptionalInt(json['reply_to']),
      specialTag: json['special_tag']?.toString(),
    );
  }
}

int _parseInt(dynamic val) {
  if (val is int) return val;
  if (val is num) return val.toInt();
  if (val is String) return int.tryParse(val) ?? 0;
  return 0;
}

int? _parseOptionalInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return value is String ? int.tryParse(value) : null;
}
