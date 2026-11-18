// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../../agent/agent_session.dart';
import '../../../agent/agent_types.dart';
import '../ehall/department_notices/department_directory.dart';
import '../ehall/department_notices/department_notice_model.dart';
import '../ehall/department_notices/department_notice_service.dart';

const _noticeSource = '复旦院系公开通知';
const _researchSource = '复旦大学新闻文化网·科研进展';
const _resultLimit = 8;
const _timeout = Duration(seconds: 10);
const _maxHtmlBytes = 1024 * 1024;

const _researchPages = [
  DepartmentInfo(
    id: 'research-page-1',
    name: _researchSource,
    shortName: '科研进展第 1 页',
    category: '科研进展',
    websiteUrl: 'https://news.fudan.edu.cn/',
    noticeUrl: 'https://news.fudan.edu.cn/235/list.htm',
  ),
  DepartmentInfo(
    id: 'research-page-2',
    name: _researchSource,
    shortName: '科研进展第 2 页',
    category: '科研进展',
    websiteUrl: 'https://news.fudan.edu.cn/',
    noticeUrl: 'https://news.fudan.edu.cn/235/list2.htm',
  ),
];

Iterable<AgentTool> publicCampusAgentTools() => [
  AgentTool(
    spec: const AgentToolSpec(
      'campus_department_notices_search',
      '按标题关键词搜索院系官网公开通知的列表首页。department 可填院系代码、全称或简称。'
          '省略时只查计算与智能、经济、基础医学和数学四个院系。',
      {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'maxLength': 80},
          'department': {'type': 'string', 'maxLength': 64},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.campus,
    label: '搜索院系通知',
    read: _searchNotices,
  ),
  AgentTool(
    spec: const AgentToolSpec(
      'campus_research_news_search',
      '按标题关键词搜索复旦大学新闻文化网公开的科研进展。范围是栏目最新两页。',
      {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'maxLength': 80},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    ),
    source: AgentSourceKind.campus,
    label: '搜索科研动态',
    read: (args) => _search(
      _researchSource,
      args['query'] as String,
      _researchPages,
      research: true,
    ),
  ),
];

String _normalize(String text) => text.trim().toLowerCase();

DepartmentInfo? _findDepartment(String input) {
  final name = _normalize(input);
  final byId = DepartmentDirectory.byId(name);
  if (byId != null) return byId;
  final matches = DepartmentDirectory.all.where((department) {
    final fullName = _normalize(department.name);
    final shortName = _normalize(department.shortName);
    return fullName == name ||
        fullName.split(RegExp(r'\s*[(（]')).first == name ||
        shortName == name ||
        shortName.split('/').contains(name);
  });
  return matches.length == 1 ? matches.single : null;
}

Future<Json> _searchNotices(Json args) async {
  final requested = args['department'] as String?;
  final department = requested == null ? null : _findDepartment(requested);
  if (requested != null && department == null) {
    return {
      'source': _noticeSource,
      'status': 'unknown_department',
      'message': '院系无法唯一识别。请提供院系代码、全称或目录简称。',
      'records': <Json>[],
      'web_links': <Json>[],
    };
  }
  final pages = department != null
      ? [department]
      : DepartmentDirectory.defaultDepartmentIds
            .take(4)
            .map(DepartmentDirectory.byId)
            .whereType<DepartmentInfo>()
            .toList();
  return _search(_noticeSource, args['query'] as String, pages);
}

Future<Json> _search(
  String source,
  String query,
  List<DepartmentInfo> pages, {
  bool research = false,
}) async {
  final lists = await Future.wait([
    for (final page in pages) _readList(page, research: research),
  ]);
  final terms = _normalize(query).split(RegExp(r'\s+'));
  final matches = [
    for (final items in lists)
      for (final item in items)
        if (terms.every(_normalize(item.title).contains)) item,
  ]..sort((a, b) => b.date.compareTo(a.date));
  final seen = <String>{};
  final window = matches
      .where((item) => seen.add(item.url))
      .take(_resultLimit + 1)
      .toList();
  final records = <Json>[
    for (final item in window.take(_resultLimit))
      {
        'title': String.fromCharCodes(item.title.runes.take(140)),
        'published_on': item.date.isEmpty ? null : item.date,
        'link': item.url,
        if (!research) 'department': item.departmentName,
      },
  ];
  final readCount = lists.where((items) => items.isNotEmpty).length;
  return {
    'source': source,
    'freshness': switch (readCount) {
      0 => 'unavailable',
      _ when readCount == pages.length => 'live',
      _ => 'partial',
    },
    'checked_at': DateTime.now().toUtc().toIso8601String(),
    'status': switch ((readCount, records.isEmpty)) {
      (0, _) => 'unavailable',
      (_, true) => 'no_match',
      _ => 'matched',
    },
    if (readCount == 0) 'message': '本次未能从所选公开列表读取可验证条目。',
    if (readCount > 0 && records.isEmpty)
      'message': '本次成功读取的公开列表中，标题没有匹配关键词的条目。',
    'scope': research ? '科研进展栏目前两页的标题' : '所列院系的公告列表首页标题',
    'lists': <Json>[
      for (var i = 0; i < pages.length; i++)
        {
          'title': research ? pages[i].shortName : _noticeLabel(pages[i]),
          'status': lists[i].isEmpty ? 'unavailable' : 'read',
          'records_read': lists[i].length,
        },
    ],
    'truncated': window.length > _resultLimit,
    'records': records,
    'web_links': <Json>[
      for (final record in records)
        {'title': record['title'], 'url': record['link']},
    ],
  };
}

String _noticeLabel(DepartmentInfo department) =>
    Uri.parse(department.noticeUrl).host == 'shmc.fudan.edu.cn'
    ? '上海医学院（共享通知公告）'
    : department.name;

final _researchTitle = RegExp(
  r'''<div\s+class=["']news_title["']\s*>\s*(<a\b[^>]*>[\s\S]*?</a>)\s*</div>''',
  caseSensitive: false,
);
final _researchDate = RegExp(
  r'''<span\s+class=["']times["']\s*>\s*(\d{4}-\d{2}-\d{2})\s*</span>''',
  caseSensitive: false,
);
final _researchArticle = RegExp(r'^/\d{4}/\d{4}/c235a\d+/page\.htm$');
final _listPage = RegExp(r'/list\d*\.(?:htm|html|psp)$', caseSensitive: false);

// The news cards repeat each URL as a thumbnail, headline, and summary.
String _researchHeadlines(String html) {
  final titles = _researchTitle.allMatches(html).toList();
  final headlines = StringBuffer();
  for (var i = 0; i < titles.length; i++) {
    final title = titles[i];
    final end = i + 1 < titles.length ? titles[i + 1].start : html.length;
    final date = _researchDate.firstMatch(html.substring(title.end, end));
    if (date != null) {
      headlines.writeln('${title.group(1)}<span>${date.group(1)}</span>');
    }
  }
  return headlines.toString();
}

bool _isFudanHttps(Uri uri) =>
    uri.scheme == 'https' &&
    (uri.host == 'fudan.edu.cn' || uri.host.endsWith('.fudan.edu.cn')) &&
    !uri.authority.contains('@') &&
    uri.port == 443;

Future<List<DepartmentNoticeItem>> _readList(
  DepartmentInfo page, {
  required bool research,
}) async {
  final configured = Uri.parse(page.noticeUrl);
  final index = configured.scheme == 'http'
      ? configured.replace(scheme: 'https')
      : configured;
  if (!_isFudanHttps(index)) return const [];

  final client = HttpClient()..connectionTimeout = _timeout;
  try {
    final html = await _fetchList(client, index).timeout(_timeout);
    if (html == null) return const [];
    final items = DepartmentNoticeService.parseHtml(
      research ? _researchHeadlines(html) : html,
      DepartmentInfo(
        id: page.id,
        name: page.name,
        shortName: research ? page.shortName : _noticeLabel(page),
        category: page.category,
        websiteUrl: page.websiteUrl,
        noticeUrl: index.toString(),
      ),
    );
    return items.where((item) {
      final link = Uri.tryParse(item.url);
      return link != null &&
          _isFudanHttps(link) &&
          link.host == index.host &&
          item.url.length <= 384 &&
          link.path != index.path &&
          !_listPage.hasMatch(link.path) &&
          (!research || _researchArticle.hasMatch(link.path));
    }).toList();
  } on Exception {
    return const [];
  } finally {
    client.close(force: true);
  }
}

Future<String?> _fetchList(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.followRedirects = false;
  request.headers.set(
    HttpHeaders.acceptHeader,
    'text/html,application/xhtml+xml',
  );
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) return null;

  final body = BytesBuilder(copy: false);
  await for (final chunk in response) {
    if (body.length + chunk.length > _maxHtmlBytes) return null;
    body.add(chunk);
  }
  return utf8.decode(body.takeBytes());
}
