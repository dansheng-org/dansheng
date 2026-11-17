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

    const ignoredKeywords = {
      '更多',
      'more',
      '下一页',
      '上一页',
      '尾页',
      '第一页',
      '首页',
      '返回',
      '返回首页',
      '联系我们',
      '学院地图',
      '网站地图',
      'English',
      '友情链接',
      '版权所有',
      '旧版入口',
      '办公机构',
      '组织机构',
      '组织架构',
      '组织框架',
      '本系概况',
      '学院概况',
      '师资队伍',
      '科学研究',
      '招生信息',
      '党建工作',
      '学生工作',
      '退休之家',
      '校友天地',
      '下载专区',
      '资料下载',
      '通知公告',
      '学院公告',
      '信息公开',
      '学术报告',
      '办事指南',
      '相关链接',
      '系友专栏',
      '总体介绍',
      '学院领导',
      '投递简历',
      '复旦校历',
      '校历',
      '办事大厅',
      '信息公开和告示',
      '规章制度',
      '教育教学',
      '人才培养',
      '历史沿革',
      '升级浏览器',
      '快速通道',
      '两院院士',
      '科技获奖',
      '管理技术',
      '查看详情',
    };

    String decodeEntities(String str) {
      return str
          .replaceAll('&quot;', '"')
          .replaceAll('&apos;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&')
          .replaceAll(RegExp(r'&#xD;&#xA;', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'&#\d+;'), ' ')
          .replaceAll(RegExp(r'&nbsp;', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    // Match <a ... href="..." ...> ... </a> where href is non-empty and non-hash
    final linkRegex = RegExp(
      r'''<a\b([^>]*href=["']([^"'#\s][^"']*)["'][^>]*)>([\s\S]*?)<\/a>''',
      caseSensitive: false,
    );
    final titleAttrRegex = RegExp(
      r'''title=["']([^"']+)["']''',
      caseSensitive: false,
    );
    // Strict date regex: year 2018-2029, month 1-12, day 1-31
    final strictDateRegex = RegExp(
      r'(?:^|[^\d])(20[12]\d)[-/.](1[0-2]|0[1-9]|[1-9])[-/.](0?[1-9]|[12]\d|3[01])(?:[^\d]|$)|(?:^|[^\d])(20[12]\d)年(1[0-2]|0[1-9]|[1-9])月(0?[1-9]|[12]\d|3[01])日',
    );
    final dayFirstRegex = RegExp(
      r'\b(0?[1-9]|[12]\d|3[01])\b[\s\S]{0,100}?(20[12]\d)[-/.](1[0-2]|0[1-9]|[1-9])(?!\d)',
    );
    final ymFirstRegex = RegExp(
      r'(20[12]\d)[-/.](1[0-2]|0[1-9]|[1-9])(?!\d)[\s\S]{0,100}?\b(0?[1-9]|[12]\d|3[01])\b',
    );

    String extractDate(String text) {
      if (text.isEmpty) return '';
      final clean = text
          .replaceAll(RegExp(r'<svg[\s\S]*?<\/svg>', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'<[^>]+>'), ' ');
      final matches = strictDateRegex.allMatches(clean).toList();
      if (matches.isNotEmpty) {
        final m = matches.last;
        final y = m.group(1) ?? m.group(4) ?? '';
        final mo = (m.group(2) ?? m.group(5) ?? '').padLeft(2, '0');
        final d = (m.group(3) ?? m.group(6) ?? '').padLeft(2, '0');
        return '$y-$mo-$d';
      }
      final dfMatches = dayFirstRegex.allMatches(clean).toList();
      if (dfMatches.isNotEmpty) {
        final m = dfMatches.last;
        final d = (m.group(1) ?? '').padLeft(2, '0');
        final y = m.group(2) ?? '';
        final mo = (m.group(3) ?? '').padLeft(2, '0');
        return '$y-$mo-$d';
      }
      final ymMatches = ymFirstRegex.allMatches(clean).toList();
      if (ymMatches.isNotEmpty) {
        final m = ymMatches.last;
        final y = m.group(1) ?? '';
        final mo = (m.group(2) ?? '').padLeft(2, '0');
        final d = (m.group(3) ?? '').padLeft(2, '0');
        return '$y-$mo-$d';
      }
      return '';
    }

    final matches = linkRegex.allMatches(html);

    for (final match in matches) {
      final attrPart = match.group(1) ?? '';
      final href = (match.group(2) ?? '').trim();
      final innerPart = match.group(3) ?? '';

      if (href.isEmpty ||
          href.startsWith('javascript') ||
          href.startsWith('mailto:') ||
          href.contains('list.htm') ||
          href.contains('list.psp') ||
          href.contains('index.htm') ||
          href.contains('index.html') ||
          href.contains('index.shtml') ||
          href.contains('index.aspx') ||
          href.contains('default.html') ||
          href == '/') {
        continue;
      }

      var rawTitle = decodeEntities(
        innerPart.replaceAll(RegExp(r'<[^>]+>'), ' '),
      );

      final titleAttrMatch =
          titleAttrRegex.firstMatch(attrPart) ??
          titleAttrRegex.firstMatch(innerPart);
      if (titleAttrMatch != null) {
        final decodedAttr = decodeEntities(titleAttrMatch.group(1) ?? '');
        if (decodedAttr.length > rawTitle.length || rawTitle.length < 5) {
          rawTitle = decodedAttr;
        }
      }

      // SPH sometimes has "标 题：... 日 期：..."
      if (rawTitle.contains('标 题：')) {
        final parts = rawTitle.split('日 期：');
        rawTitle = parts[0].replaceAll('标 题：', '').trim();
      }

      // Strip trailing dates or NEW badges
      rawTitle = rawTitle
          .replaceAll(RegExp(r'\bNEW\b'), '')
          .replaceAll(RegExp(r'\b20\d{2}[-/.]\d{1,2}[-/.]\d{1,2}\b'), '')
          .trim();

      // Check if title is inside sibling or parent elements (e.g. stretched-link on FIT)
      if (rawTitle.isEmpty ||
          rawTitle.length < 4 ||
          RegExp(r'^\d+$').hasMatch(rawTitle) ||
          RegExp(r'^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$').hasMatch(rawTitle)) {
        final start = (match.start - 200).clamp(0, html.length);
        final end = (match.end + 200).clamp(0, html.length);
        final contextSlice = html.substring(start, end);
        final pMatch = RegExp(
          r'''<(?:p|span|div|h\d)[^>]*(?:class=["'][^"']*(?:tt|title|name)[^"']*["'])?[^>]*>([^<]{5,100})<\/(?:p|span|div|h\d)>''',
          caseSensitive: false,
        ).firstMatch(contextSlice);
        if (pMatch != null) {
          final candidate = pMatch.group(1)?.trim() ?? '';
          if (candidate.length > 4 &&
              !RegExp(r'^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$').hasMatch(candidate)) {
            rawTitle = decodeEntities(candidate);
          }
        }
      }

      if (rawTitle.isEmpty ||
          rawTitle.length < 4 ||
          RegExp(r'^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$').hasMatch(rawTitle)) {
        continue;
      }
      if (ignoredKeywords.contains(rawTitle) ||
          ignoredKeywords.contains('[$rawTitle]')) {
        continue;
      }
      if (rawTitle.contains('下一页') ||
          rawTitle.contains('上一页') ||
          rawTitle.contains('尾页') ||
          rawTitle.contains('第一页') ||
          rawTitle.startsWith('返回')) {
        continue;
      }

      final fullUrl = resolveUrl(department.noticeUrl, href);

      // Find publication date in inner HTML or surrounding context
      var dateStr = extractDate(innerPart);

      if (dateStr.isEmpty) {
        final rawAfter = html.substring(
          match.end,
          (match.end + 500).clamp(0, html.length),
        );
        final nextA = rawAfter.indexOf('<a');
        final forwardSlice = nextA != -1
            ? rawAfter.substring(0, nextA)
            : rawAfter;
        dateStr = extractDate(forwardSlice);
      }

      if (dateStr.isEmpty) {
        final rawBefore = html.substring(
          (match.start - 500).clamp(0, html.length),
          match.start,
        );
        final prevA = rawBefore.lastIndexOf('</a>');
        final backwardSlice = prevA != -1
            ? rawBefore.substring(prevA)
            : rawBefore;
        dateStr = extractDate(backwardSlice);
      }

      // If already seen this URL, prefer the one with longer/better title and date
      if (seenUrls.contains(fullUrl)) {
        final existingIndex = items.indexWhere((it) => it.url == fullUrl);
        if (existingIndex != -1) {
          final existing = items[existingIndex];
          final betterTitle = rawTitle.length > existing.title.length
              ? rawTitle
              : existing.title;
          final betterDate = dateStr.isNotEmpty ? dateStr : existing.date;
          items[existingIndex] = DepartmentNoticeItem(
            id: existing.id,
            title: betterTitle,
            url: fullUrl,
            date: betterDate,
            departmentId: department.id,
            departmentName: department.shortName,
          );
        }
        continue;
      }

      final isArticle =
          RegExp(
            r'\/c\d+a\d+\/page|\/info\/\d+\/\d+|\/Data\/View\/\d+|\/a\/\d+|fdsm\d+|lists-notice|show-\d+-\d+|\/\d{4}\/\d{4}\/c\d+a\d+',
            caseSensitive: false,
          ).hasMatch(href) ||
          dateStr.isNotEmpty;

      if (isArticle) {
        seenUrls.add(fullUrl);
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
    }

    // Filter to dated items if plenty exist to exclude static sidebar article links
    final datedItems = items
        .where((it) => it.date.isNotEmpty && it.date.length >= 8)
        .toList();
    if (datedItems.length >= 3) {
      return datedItems;
    }

    return items;
  }

  /// Fetches notice items for one department over HTTP.
  Future<List<DepartmentNoticeItem>> fetchDepartmentNotices(
    DepartmentInfo department,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..badCertificateCallback = (cert, host, port) => true;
    try {
      final request = await client
          .getUrl(Uri.parse(department.noticeUrl))
          .timeout(const Duration(seconds: 8));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        return _cache[department.id] ?? const [];
      }
      final bytes = await response
          .fold<List<int>>(<int>[], (acc, data) => acc..addAll(data))
          .timeout(const Duration(seconds: 8));
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
        TileFacts(note: departmentIds.isEmpty ? '未订阅任何院系' : '暂无最新院系公告'),
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
