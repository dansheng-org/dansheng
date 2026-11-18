// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/web_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'queries Brave using the subscription header and projects HTTPS results',
    () async {
      final client = _Client(200, {
        'web': {
          'results': [
            {
              'title': '<b>公告</b>',
              'url': 'https://example.test/a',
              'description': '摘要',
            },
            {'title': '重复链接', 'url': 'https://example.test/a'},
            {'title': '浏览器指令', 'url': 'javascript:alert(1)'},
            {'title': '凭据地址', 'url': 'https://example@example.test'},
          ],
        },
      });
      final search = BraveWebSearch(
        'fixture-search-key',
        createClient: () => client,
      );
      final result = await search.search('  公开公告  ');
      expect(client.uri?.origin, 'https://api.search.brave.com');
      expect(client.uri?.path, '/res/v1/web/search');
      expect(client.uri?.queryParameters, containsPair('q', '公开公告'));
      expect(client.uri.toString(), isNot(contains('fixture-search-key')));
      expect(
        client.request.headers.values['x-subscription-token'],
        'fixture-search-key',
      );
      expect(client.request.followRedirects, isFalse);
      expect(client.closed, isTrue);
      expect(result['records'], [
        {'title': '公告', 'url': 'https://example.test/a', 'snippet': '摘要'},
      ]);
    },
  );

  test(
    'a redirect is rejected without sharing credentials with the destination',
    () async {
      final client = _Client(302, {});
      await expectLater(
        BraveWebSearch(
          'fixture-search-key',
          createClient: () => client,
        ).search('公告'),
        throwsA(isA<AgentFailure>()),
      );
      expect(client.request.followRedirects, isFalse);
      expect(client.closed, isTrue);
    },
  );
}

class _Client implements HttpClient {
  _Client(int status, Json response) : request = _Request(status, response);

  final _Request request;
  Uri? uri;
  bool closed = false;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    uri = url;
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(int status, Json response) : _response = _Response(status, response);

  final _Response _response;

  @override
  final _Headers headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, Json response)
    : _body = Stream.value(utf8.encode(jsonEncode(response)));

  final Stream<List<int>> _body;

  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
