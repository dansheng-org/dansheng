// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../board/tile_data.dart';
import '../board/tile_facts.dart';
import 'department_directory.dart';
import 'department_notice_model.dart';

/// Service responsible for fetching, parsing, and caching department notices.
class DepartmentNoticeService {
  DepartmentNoticeService._();

  static final DepartmentNoticeService instance = DepartmentNoticeService._();

  /// Cached notices per department ID.
  final Map<String, List<DepartmentNoticeItem>> _cache = {};

  /// Timestamp of the last successful read.
  DateTime? _lastObserved;

  /// Inflight fetches to prevent duplicate concurrent network calls.
  final Map<String, Future<List<DepartmentNoticeItem>>> _inflight = {};

  /// Resolves a relative URL against a base URL.
  static String resolveUrl(String baseUrl, String relative) {
    if (relative.startsWith('http://') || relative.startsWith('https://')) {
      return relative;
    }
    try {
      final base = Uri.parse(baseUrl);
      return base.resolve(relative).toString();
    } catch (_) {
      return relative;
    }
  }

  /// Parses notice items from WebPlus HTML string.
  static List<DepartmentNoticeItem> parseHtml(
    String html,
    DepartmentInfo department,
  ) {
    final items = <DepartmentNoticeItem>[];
    final seenUrls = <String>{};

    // Regex for standard table or list rows containing a link and a date
    final rowRegex = RegExp(
      r'<(?:tr|li)[^>]*>([\s\S]*?)<\/(?:tr|li)>',
      caseSensitive: false,
    );
    final linkRegex = RegExp(
      r'<a\s+[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>',
      caseSensitive: false,
    );
    final dateRegex = RegExp(r'(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})');

    final rows = rowRegex.allMatches(html);

    for (final row in rows) {
      final rowText = row.group(1) ?? '';
      final linkMatch = linkRegex.firstMatch(rowText);
      if (linkMatch == null) continue;

      final href = linkMatch.group(1)?.trim() ?? '';
      if (href.isEmpty ||
          href.startsWith('#') ||
          href.startsWith('javascript') ||
          href.contains('list.htm') ||
          href.contains('index.') ||
          href.contains('main.')) {
        continue;
      }

      var rawTitle = (linkMatch.group(2) ?? '')
          .replaceAll(RegExp(r'<[^>]+>'), '')
          .trim();
      // If title was in title attribute:
      if (rawTitle.isEmpty || rawTitle.length < 3) {
        final titleAttr = RegExp(r'title="([^"]+)"').firstMatch(rowText);
        if (titleAttr != null) {
          rawTitle = titleAttr.group(1)?.trim() ?? rawTitle;
        }
      }

      if (rawTitle.isEmpty ||
          rawTitle.length < 3 ||
          rawTitle == '更多' ||
          rawTitle.toLowerCase() == 'more') {
        continue;
      }

      final dateMatch = dateRegex.firstMatch(rowText);
      final dateStr = dateMatch != null
          ? dateMatch.group(1)!.replaceAll('/', '-').replaceAll('.', '-')
          : '';

      final fullUrl = resolveUrl(department.noticeUrl, href);
      if (!seenUrls.add(fullUrl)) continue;

      items.add(
        DepartmentNoticeItem(
          id: '${department.id}_${fullUrl.hashCode}',
          title: rawTitle,
          url: fullUrl,
          date: dateStr,
          departmentId: department.id,
          departmentName: department.shortName,
        ),
      );
    }

    // Fallback parser if row regex did not match (e.g. customized div layouts)
    if (items.isEmpty) {
      final allLinks = linkRegex.allMatches(html);
      for (final link in allLinks) {
        final href = link.group(1)?.trim() ?? '';
        final text = (link.group(2) ?? '')
            .replaceAll(RegExp(r'<[^>]+>'), '')
            .trim();
        if (text.length > 5 &&
            !href.startsWith('#') &&
            !href.startsWith('javascript') &&
            !href.contains('list.htm') &&
            seenUrls.add(href)) {
          final fullUrl = resolveUrl(department.noticeUrl, href);
          items.add(
            DepartmentNoticeItem(
              id: '${department.id}_${fullUrl.hashCode}',
              title: text,
              url: fullUrl,
              date: '',
              departmentId: department.id,
              departmentName: department.shortName,
            ),
          );
        }
      }
    }

    return items;
  }

  /// Fetches notice items for one department over HTTP.
  Future<List<DepartmentNoticeItem>> fetchDepartmentNotices(
    DepartmentInfo department,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client
          .getUrl(Uri.parse(department.noticeUrl))
          .timeout(const Duration(seconds: 5));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) DanshengDepartmentNotices/1.0',
      );
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        return _cache[department.id] ?? const [];
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (acc, data) => acc..addAll(data))
          .timeout(const Duration(seconds: 5));
      final html = utf8.decode(bytes, allowMalformed: true);
      final items = parseHtml(html, department);
      if (items.isNotEmpty) {
        _cache[department.id] = items;
        _lastObserved = DateTime.now();
      }
      return items;
    } catch (_) {
      return _cache[department.id] ?? const [];
    } finally {
      client.close();
    }
  }

  /// Gets notices for a set of subscribed department IDs.
  Future<List<DepartmentNoticeItem>> getNotices(
    List<String> departmentIds, {
    bool refresh = false,
  }) async {
    final validDepts = departmentIds
        .map(DepartmentDirectory.byId)
        .whereType<DepartmentInfo>()
        .toList();

    if (!refresh) {
      final cachedList = <DepartmentNoticeItem>[];
      var hasAnyCache = false;
      for (final d in validDepts) {
        final cached = _cache[d.id];
        if (cached != null && cached.isNotEmpty) {
          cachedList.addAll(cached);
          hasAnyCache = true;
        }
      }
      if (hasAnyCache) {
        cachedList.sort((a, b) => b.date.compareTo(a.date));
        return cachedList;
      }
    }

    // Fetch concurrently
    final futures = <Future<List<DepartmentNoticeItem>>>[];
    for (final d in validDepts) {
      final task = _inflight.putIfAbsent(
        d.id,
        () => fetchDepartmentNotices(d).whenComplete(() {
          _inflight.remove(d.id);
        }),
      );
      futures.add(task);
    }

    final results = await Future.wait(futures);
    final allNotices = <DepartmentNoticeItem>[];
    for (final list in results) {
      allNotices.addAll(list);
    }
    allNotices.sort((a, b) => b.date.compareTo(a.date));
    return allNotices;
  }

  /// Computes TileData for the EHallTile face.
  Future<TileData?> getTileData(
    List<String> departmentIds, {
    bool live = false,
  }) async {
    final notices = await getNotices(departmentIds, refresh: live);
    if (notices.isEmpty) {
      return TileData(
        TileFacts(
          note: departmentIds.isEmpty ? '未订阅任何院系' : '暂无最新院系公告',
        ),
        observedAt: _lastObserved,
      );
    }

    final first = notices.first;
    final firstNote = first.date.isNotEmpty
        ? '[${first.departmentName}] ${first.date} ${first.title}'
        : '[${first.departmentName}] ${first.title}';

    return TileData(
      TileFacts(
        value: notices.length.toString(),
        unit: '条',
        note: firstNote,
        rows: [
          for (final n in notices.skip(1).take(5))
            TileFact(
              '[${n.departmentName}] ${n.title}',
              value: n.date.isNotEmpty && n.date.length >= 10
                  ? n.date.substring(5) // MM-DD
                  : n.date,
            ),
        ],
      ),
      observedAt: _lastObserved,
    );
  }

  /// Injects test fixture notices (useful in unit/widget tests).
  @visibleForTesting
  void injectFixtures(String departmentId, List<DepartmentNoticeItem> items) {
    _cache[departmentId] = items;
    _lastObserved = DateTime.now();
  }

  /// Clears cache.
  @visibleForTesting
  void clear() {
    _cache.clear();
    _lastObserved = null;
    _inflight.clear();
  }
}
