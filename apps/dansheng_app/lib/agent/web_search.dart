// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_session.dart';
import 'agent_types.dart';

const agentWebQueryLimit = 200;

class BraveWebSearch {
  BraveWebSearch(this._apiKey, {HttpClient Function()? createClient})
    : _createClient = createClient ?? HttpClient.new;

  final String _apiKey;
  final HttpClient Function() _createClient;

  AgentTool get tool => AgentTool(
    spec: const AgentToolSpec('web_search', '用公开关键词搜索网页，返回标题、链接和摘要。', {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'maxLength': agentWebQueryLimit},
      },
      'required': ['query'],
      'additionalProperties': false,
    }),
    source: AgentSourceKind.web,
    label: '正在搜索网页…',
    read: (args) => search(args['query'] as String),
  );

  Future<Json> search(String query) async {
    final phrase = query.trim();
    if (phrase.isEmpty || phrase.length > agentWebQueryLimit) {
      throw const AgentFailure('搜索关键词过长或为空。');
    }
    if (_apiKey.isEmpty ||
        _apiKey.length > 4096 ||
        _apiKey.codeUnits.any((unit) => unit < 33 || unit > 126)) {
      throw const AgentFailure('请检查 Brave Search 密钥。');
    }
    const timeout = Duration(seconds: 15);
    final client = _createClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.https('api.search.brave.com', '/res/v1/web/search', {
        'q': phrase,
        'count': '5',
        'safesearch': 'moderate',
        'result_filter': 'web',
        'text_decorations': 'false',
        if (RegExp(r'[\u3400-\u9fff]').hasMatch(phrase))
          'search_lang': 'zh-hans',
      });
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set('X-Subscription-Token', _apiKey);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        throw AgentFailure(switch (response.statusCode) {
          401 || 403 => 'Brave Search 拒绝了请求，请检查密钥或权限。',
          429 => 'Brave Search 请求受到限流，请稍后再试。',
          _ => '网页搜索服务暂时不可用。',
        });
      }
      final body = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (body.length + chunk.length > 512 * 1024) {
          throw const AgentFailure('网页搜索响应过大。');
        }
        body.addAll(chunk);
      }
      return _parse(jsonDecode(utf8.decode(body)));
    } on AgentFailure {
      rethrow;
    } on TimeoutException {
      throw const AgentFailure('网页搜索超时。');
    } on FormatException {
      throw const AgentFailure('网页搜索服务返回了无效数据。');
    } catch (_) {
      throw const AgentFailure('暂时无法连接网页搜索服务。');
    } finally {
      client.close(force: true);
    }
  }

  Json _parse(Object? body) {
    if (body is! Json) throw const FormatException();
    final web = body['web'];
    final raw = web is Json ? web['results'] : null;
    if (web != null && raw is! List) throw const FormatException();
    final results = <Json>[];
    final urls = <Uri>{};
    if (raw is List) {
      for (final row in raw.whereType<Json>()) {
        final link = AgentWebLink.fromJson(row);
        if (link == null ||
            link.uri.toString().length > 1024 ||
            !urls.add(link.uri)) {
          continue;
        }
        results.add({
          'title': _plainText(link.title, 140),
          'url': link.uri.toString(),
          'snippet': _plainText(row['description'], 300),
        });
        if (results.length == 5) break;
      }
    }
    return {'source': 'Brave Search', 'records': results};
  }
}

String _plainText(Object? value, int length) => value is String
    ? String.fromCharCodes(
        value.replaceAll(RegExp(r'<[^>]*>'), '').trim().runes.take(length),
      )
    : '';
