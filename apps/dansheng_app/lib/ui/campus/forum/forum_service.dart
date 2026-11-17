// SPDX-License-Identifier: GPL-3.0-or-later
import '../campus_api.dart';
import 'forum_models.dart';
import 'forum_pagination.dart';

/// Service adapter for Forum operations on CampusApi.
class ForumService {
  final CampusApi api;

  ForumService(this.api);

  /// Fetch all divisions; [cached] reads the host's copy of the last
  /// successful answer instead of asking the forum.
  Future<List<TeaDivision>> fetchDivisions({bool cached = false}) async {
    final response = cached
        ? await api.call('campus.cached', {'method': 'community.tea.divisions'})
        : await api.call('community.tea.divisions');
    return _extractList(response)
        .map((item) => TeaDivision.fromJson(item))
        .toList();
  }

  /// Fetch holes (paginated by before timestamp).
  Future<List<TeaHole>> fetchHoles({
    int? divisionId,
    DateTime? before,
    String? tag,
    int pageSize = forumPageSize,
    ForumSortOrder order = ForumSortOrder.lastReplied,
  }) async {
    final size = pageSize.clamp(1, forumHolesMaxPageSize);
    final params = <String, dynamic>{
      'page_size': size,
      'size': size,
      'order': order.value,
    };
    if (divisionId != null && divisionId > 0) {
      params['division'] = divisionId;
      params['division_id'] = divisionId;
    }
    if (before != null) {
      params['before'] = before.toUtc().toIso8601String();
    }
    if (tag != null && tag.trim().isNotEmpty) {
      final cleanTag = tag.trim().replaceFirst(RegExp(r'^#'), '');
      if (cleanTag.isNotEmpty) {
        params['tag'] = cleanTag;
      }
    }

    final response = await api.call('community.tea.holes', params);
    return _extractList(response)
        .map((item) => TeaHole.fromJson(item))
        .toList();
  }

  /// Fetch single hole by ID.
  Future<TeaHole?> fetchHole(int holeId) async {
    final response = await api.call('community.tea.hole', {'hole_id': holeId});
    final map = _extractMap(response);
    if (map.isEmpty) return null;
    return TeaHole.fromJson(map);
  }

  /// The account's favourite holes as the forum keeps them.
  Future<List<TeaHole>> fetchFavorites() async {
    final response = await api.call('community.tea.favorites');
    return _extractList(response).map(TeaHole.fromJson).toList();
  }

  /// Stars or unstars a hole on the forum account.
  Future<void> setFavorite(int holeId, bool favorite) async {
    await api.call('forum.favorite', {'hole_id': holeId, 'favorite': favorite});
  }

  /// Fetch floors of a hole.
  /// Passes both page_size and size to ensure full compatibility with core adapter.
  Future<List<TeaFloor>> fetchFloors({
    required int holeId,
    int offset = 0,
    int size = forumPageSize,
  }) async {
    final response = await api.call('community.tea.floors', {
      'hole_id': holeId,
      'offset': offset,
      'size': size,
      'page_size': size,
    });
    return _extractList(response)
        .map((item) => TeaFloor.fromJson(item))
        .toList();
  }

  /// Search forum by keyword.
  Future<List<ForumSearchResult>> search({
    required String query,
    int offset = 0,
    int size = forumPageSize,
  }) async {
    final response = await api.call('forum.search', {
      'query': query,
      'offset': offset,
      'size': size,
    });
    return _extractList(response)
        .map((item) => ForumSearchResult.fromJson(item))
        .toList();
  }

  /// Publish a new hole.
  Future<int?> publish({
    required int divisionId,
    required String content,
    required List<String> tags,
  }) async {
    final response = await api.call('forum.publish', {
      'division_id': divisionId,
      'content': content,
      'tags': tags,
    });
    return _extractHoleId(response);
  }

  /// Reply to an existing hole.
  Future<int?> reply({required int holeId, required String content}) async {
    final response = await api.call('forum.reply', {
      'hole_id': holeId,
      'content': content,
    });
    return _extractFloorId(response);
  }

  /// Read-only reconciliation of uncertain publish or reply submission.
  /// Calls parent forum.reconcile with {action: 'publish'|'reply', division_id|hole_id, content}.
  Future<Map<String, dynamic>?> reconcile({
    required String action,
    int? divisionId,
    int? holeId,
    required String content,
  }) async {
    final params = <String, dynamic>{'action': action, 'content': content};
    if (divisionId != null && divisionId > 0) {
      params['division_id'] = divisionId;
      params['target_id'] = divisionId;
    }
    if (holeId != null && holeId > 0) {
      params['hole_id'] = holeId;
      params['target_id'] = holeId;
    }

    try {
      final res = await api.call('forum.reconcile', params);
      if (res is Map<String, dynamic>) return res;
      if (res is Map) return Map<String, dynamic>.from(res);
      return null;
    } catch (e) {
      final str = e.toString();
      // Handle fallback alias if host routed as community.tea.reconcile
      if (str.contains('MethodNotFound') || str.contains('unknown')) {
        final res = await api.call('community.tea.reconcile', params);
        if (res is Map<String, dynamic>) return res;
        if (res is Map) return Map<String, dynamic>.from(res);
      }
      rethrow;
    }
  }

  /// Determines whether a reconciliation result is a definitive committed match.
  /// Empty or ambiguous responses return false.
  static bool isDefinitiveMatch(Map<String, dynamic>? result) {
    if (result == null || result.isEmpty) return false;

    final status = result['status']?.toString();
    if (status == 'pending' || status == 'uncertain' || status == 'failed') {
      return false;
    }

    final isCommitted = status == 'committed';
    final isReconciled = result['reconciled'] == true;
    final isDuplicate = result['duplicate'] == true;

    if (isCommitted || isReconciled || isDuplicate) {
      return true;
    }

    final holeId = _extractInt(result['hole_id']);
    final floorId = _extractInt(result['floor_id']);
    if (holeId != null && holeId > 0) return true;
    if (floorId != null && floorId > 0) return true;

    if (result['outcome'] is Map) {
      final outcome = result['outcome'] as Map;
      if (outcome['status'] == 'committed' ||
          outcome['hole_id'] != null ||
          outcome['floor_id'] != null) {
        return true;
      }
    }

    return false;
  }

  /// Trigger forum login flow via parent CampusApi. The saved credentials are
  /// used first and the host asks for new ones only when they are rejected;
  /// [replace] asks right away, to switch to another forum account.
  Future<void> login({bool replace = false}) async {
    await api.call('campus.login', {
      'service': 'forum',
      if (replace) 'replace': true,
    });
  }

  static int? _extractHoleId(dynamic response) {
    if (response is int) return response;
    if (response is Map) {
      if (response['hole_id'] != null) {
        return _extractInt(response['hole_id']);
      }
      if (response['response'] is Map) {
        final inner = response['response'] as Map;
        if (inner['hole_id'] != null) return _extractInt(inner['hole_id']);
        if (inner['data'] != null) return _extractInt(inner['data']);
      }
      if (response['outcome'] is Map) {
        final inner = response['outcome'] as Map;
        if (inner['hole_id'] != null) return _extractInt(inner['hole_id']);
      }
      if (response['data'] != null) return _extractInt(response['data']);
    }
    return null;
  }

  static int? _extractFloorId(dynamic response) {
    if (response is int) return response;
    if (response is Map) {
      if (response['floor_id'] != null) {
        return _extractInt(response['floor_id']);
      }
      if (response['response'] is Map) {
        final inner = response['response'] as Map;
        if (inner['floor_id'] != null) return _extractInt(inner['floor_id']);
        if (inner['data'] != null) return _extractInt(inner['data']);
      }
      if (response['outcome'] is Map) {
        final inner = response['outcome'] as Map;
        if (inner['floor_id'] != null) return _extractInt(inner['floor_id']);
      }
      if (response['data'] != null) return _extractInt(response['data']);
    }
    return null;
  }

  static int? _extractInt(dynamic val) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val);
    return null;
  }

  /// Helper to unpack a list from either a direct List or a SourceBatch map.
  List<Map<String, dynamic>> _extractList(dynamic res) {
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
        return (res['items'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
      }
      if (res['results'] is List) {
        return (res['results'] as List)
            .whereType<Map<String, dynamic>>()
            .toList();
      }
    }
    return <Map<String, dynamic>>[];
  }

  /// Helper to unpack a map from either a direct Map or a SourceRecord map.
  Map<String, dynamic> _extractMap(dynamic res) {
    if (res is Map<String, dynamic>) {
      if (res['payload'] is Map<String, dynamic>) {
        return res['payload'] as Map<String, dynamic>;
      }
      return res;
    }
    return <String, dynamic>{};
  }
}
