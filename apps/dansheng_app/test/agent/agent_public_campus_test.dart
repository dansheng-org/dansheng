// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/ui/campus/agent/agent_public_campus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final tools = {
    for (final tool in publicCampusAgentTools()) tool.spec.name: tool,
  };
  final notices = tools['campus_department_notices_search']!;
  final research = tools['campus_research_news_search']!;

  test('public tools use the campus source and require a title query', () {
    for (final tool in tools.values) {
      expect(tool.source, AgentSourceKind.campus);
      expect(tool.accepts({'query': '博士'}), isTrue);
      expect(tool.accepts({'query': ' '}), isFalse);
      expect(
        tool.accepts({'query': '博士', 'url': 'https://example.com'}),
        isFalse,
      );
    }
  });

  test(
    'department aliases scope the request and links share the list host',
    () async {
      final requests = <Uri>[];
      final result = await _withPages(
        () => notices.read({'query': '学术 讲座', 'department': '数院'}),
        (uri) {
          requests.add(uri);
          return const _Page(200, '''
        <a href="/c30286a101/page.htm">研究生学术讲座通知</a><span>2026-11-14</span>
        <a href="https://other.fudan.edu.cn/c30286a102/page.htm">外部学术讲座通知</a>
        <a href="http://math.fudan.edu.cn/c30286a103/page.htm">旧址学术讲座通知</a>
      ''');
        },
      );
      expect(requests.map((uri) => uri.toString()), [
        'https://math.fudan.edu.cn/30286/list.htm',
      ]);
      expect(result['freshness'], 'live');
      expect(result['records'], [
        {
          'title': '研究生学术讲座通知',
          'published_on': '2026-11-14',
          'department': '数学科学学院',
          'link': 'https://math.fudan.edu.cn/c30286a101/page.htm',
        },
      ]);
      expect(result['web_links'], [
        {
          'title': '研究生学术讲座通知',
          'url': 'https://math.fudan.edu.cn/c30286a101/page.htm',
        },
      ]);
    },
  );

  test('an unknown department avoids a network request', () async {
    final result = await _withPages(
      () => notices.read({'query': '讲座', 'department': '未收录院系'}),
      (_) => throw StateError('Unexpected campus fetch'),
    );
    expect(result['status'], 'unknown_department');
    expect(result['records'], isEmpty);
    expect(result['web_links'], isEmpty);
  });

  test(
    'research emits distinct capped headlines and reports partial reads',
    () async {
      final requests = <Uri>[];
      final cards = [
        for (var id = 1; id <= 9; id++) _researchCard(id),
        _researchCard(9),
      ].join();
      _Page page(Uri uri) {
        requests.add(uri);
        return uri.path == '/235/list.htm'
            ? _Page(200, cards)
            : const _Page(302, '');
      }

      final result = await _withPages(
        () => research.read({'query': '量子'}),
        page,
      );
      expect(requests.map((uri) => uri.path), [
        '/235/list.htm',
        '/235/list2.htm',
      ]);
      expect(result['status'], 'matched');
      expect(result['freshness'], 'partial');
      expect(result['truncated'], isTrue);
      final records = result['records'] as List<Json>;
      expect(records, hasLength(8));
      expect(records.map((record) => record['link']).toSet(), hasLength(8));
      expect(records.first, {
        'title': '量子科研进展 9',
        'published_on': '2026-11-09',
        'link': 'https://news.fudan.edu.cn/2026/1109/c235a9/page.htm',
      });
      expect(result['web_links'], hasLength(records.length));

      final empty = await _withPages(
        () => research.read({'query': '仅摘要出现'}),
        page,
      );
      expect(empty['status'], 'no_match');
      expect(empty['freshness'], 'partial');
      expect(empty['records'], isEmpty);

      final unavailable = await _withPages(
        () => research.read({'query': '量子'}),
        (_) => const _Page(200, '<html>unexpected page layout</html>'),
      );
      expect(unavailable['status'], 'unavailable');
      expect(unavailable['freshness'], 'unavailable');
    },
  );
}

String _researchCard(int id) {
  final day = '0$id';
  final path = '/2026/11$day/c235a$id/page.htm';
  return '''
    <div><a href='$path'><img src="thumb.jpg"></a></div>
    <div class="news_title"><a href='$path'>量子科研进展 $id</a></div>
    <div class="news_text"><a href='$path'>仅摘要出现在此处，正文摘要长度超过标题</a></div>
    <div class="news_time"><span class="times">2026-11-$day</span></div>
  ''';
}

Future<Json> _withPages(
  Future<Json> Function() read,
  _Page Function(Uri) page,
) => HttpOverrides.runZoned(read, createHttpClient: (_) => _Client(page));

class _Client implements HttpClient {
  _Client(this.page);
  final _Page Function(Uri) page;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(page(url));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.page);
  final _Page page;

  @override
  final HttpHeaders headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async {
    expect(followRedirects, isFalse);
    return _Response(page);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Page {
  const _Page(this.status, this.html);
  final int status;
  final String html;
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(_Page page)
    : statusCode = page.status,
      super(Stream.value(utf8.encode(page.html)));

  @override
  final int statusCode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
