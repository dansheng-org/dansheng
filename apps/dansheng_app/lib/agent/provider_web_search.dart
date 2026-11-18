// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_session.dart';
import 'agent_types.dart';
import 'web_search.dart' show agentWebQueryLimit;

const _deepSeekQueryLimit = 128;
const _maxRecords = 5;
const _maxResponseBytes = 512 * 1024;
const _timeout = Duration(seconds: 25);
const _openAiFallback = '请在设置中配置 Brave Search 密钥以搜索网页。';
const _invalidQuery = AgentFailure('搜索关键词过长或为空。');

enum _SearchApi {
  deepSeek('DeepSeek Search', ['v1', 'tools', 'search']),
  responses('OpenAI Web Search', ['responses']),
  chatCompletions('OpenAI Web Search', ['chat', 'completions']),
  messages('Anthropic Web Search', ['messages']);

  const _SearchApi(this.source, this.path);

  final String source;
  final List<String> path;

  bool get isOpenAi => this == responses || this == chatCompletions;
}

class ProviderWebSearch {
  ProviderWebSearch(this._config, {HttpClient Function()? createClient})
    : _createClient = createClient ?? HttpClient.new;

  final AgentModelConfig _config;
  final HttpClient Function() _createClient;

  _SearchApi get _api {
    final base = _config.baseUrl;
    if (base.scheme == 'https' &&
        base.host == 'api.deepseek.com' &&
        base.port == 443) {
      return _SearchApi.deepSeek;
    }
    if (_config.provider == ModelProvider.anthropic) return _SearchApi.messages;
    return _config.model == 'gpt-5-search-api'
        ? _SearchApi.chatCompletions
        : _SearchApi.responses;
  }

  AgentTool get tool => _ProviderSearchTool(this, _api == _SearchApi.deepSeek);

  Future<Json> search(String query) async {
    final api = _api;
    final phrase = query.trim();
    if (!_validQuery(phrase, deepSeek: api == _SearchApi.deepSeek)) {
      throw _invalidQuery;
    }

    HttpClient? client;
    try {
      final base = AgentModelConfig.parseBaseUrl(_config.baseUrl.toString());
      final endpoint = _endpoint(base, api);
      final key = _config.apiKey;
      if (key.isEmpty ||
          key.length > 4096 ||
          key.codeUnits.any((unit) => unit <= 32 || unit >= 127) ||
          (api != _SearchApi.deepSeek &&
              (_config.model.trim().isEmpty || _config.model.length > 256))) {
        throw const AgentFailure('请检查模型名称和 API 密钥。');
      }

      client = _createClient();
      client.connectionTimeout = _timeout;
      final body = await _post(client, endpoint, api, phrase).timeout(_timeout);
      final rows = switch (api) {
        _SearchApi.deepSeek => _requiredObjects(body['results']),
        _SearchApi.responses => _responsesResults(body),
        _SearchApi.chatCompletions => _chatResults(body),
        _SearchApi.messages => _anthropicResults(body),
      };
      final records = _project(rows);
      if (api.isOpenAi && records.isEmpty) {
        throw const AgentFailure('模型网页搜索未返回可验证的链接。$_openAiFallback');
      }
      return {'source': api.source, 'records': records};
    } on AgentFailure {
      rethrow;
    } on TimeoutException {
      throw const AgentFailure('网页搜索超时。');
    } on FormatException {
      throw AgentFailure(
        api.isOpenAi
            ? '模型 API 地址或网页搜索响应无效。$_openAiFallback'
            : '模型 API 地址或网页搜索响应无效。',
      );
    } catch (_) {
      throw const AgentFailure('暂时无法连接网页搜索服务。');
    } finally {
      client?.close(force: true);
    }
  }

  Future<Json> _post(
    HttpClient client,
    Uri endpoint,
    _SearchApi api,
    String query,
  ) async {
    final body = utf8.encode(jsonEncode(_payload(api, query)));
    final request = await client.postUrl(endpoint);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.contentType = ContentType.json;
    if (api == _SearchApi.messages) {
      request.headers.set('x-api-key', _config.apiKey);
      request.headers.set('anthropic-version', '2023-06-01');
    } else {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_config.apiKey}',
      );
    }
    request.contentLength = body.length;
    request.add(body);

    final response = await request.close();
    final status = response.statusCode;
    if (status != HttpStatus.ok) {
      throw AgentFailure(switch (status) {
        401 => '网页搜索鉴权失败，请检查模型 API 密钥。',
        402 => '网页搜索服务余额不足。',
        403 when api.isOpenAi => '网页搜索请求被拒绝，请检查模型 API 权限。$_openAiFallback',
        403 => '网页搜索请求被拒绝，请检查模型 API 权限。',
        429 => '网页搜索请求受到限流，请稍后再试。',
        400 || 404 || 405 || 422 || 501 when api.isOpenAi =>
          '当前模型或 API 地址无法使用 OpenAI 网页搜索。$_openAiFallback',
        _ => '网页搜索服务暂时不可用。',
      });
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _maxResponseBytes) {
        throw const AgentFailure('网页搜索响应过大。');
      }
      bytes.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Json) throw const FormatException();
    return decoded;
  }

  Json _payload(_SearchApi api, String query) => switch (api) {
    _SearchApi.deepSeek => {
      'query': query,
      'count': _maxRecords,
      'need_content': false,
    },
    _SearchApi.responses => {
      'model': _config.model,
      'input': query,
      'instructions':
          'Search the public web for the supplied query and cite the results.',
      'tools': [
        {'type': 'web_search'},
      ],
      'tool_choice': 'required',
      'max_tool_calls': 1,
      'max_output_tokens': 1024,
      'store': false,
    },
    _SearchApi.chatCompletions => {
      'model': _config.model,
      'messages': [
        {'role': 'user', 'content': query},
      ],
      'web_search_options': <String, Object?>{},
      'max_completion_tokens': 1024,
    },
    _SearchApi.messages => {
      'model': _config.model,
      'system': 'Search the public web once for the supplied query and cite the results.',
      'messages': [
        {'role': 'user', 'content': query},
      ],
      'tools': [
        {'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': 1},
      ],
      'max_tokens': 1024,
    },
  };

  List<Json> _project(Iterable<Json> rows) {
    final records = <Json>[];
    final seen = <Uri>{};
    final key = _config.apiKey;
    final encodedKey = Uri.encodeComponent(key);
    for (final row in rows) {
      final title = _plainText(row['title'], 140, key);
      final link = AgentWebLink.fromJson({'title': title, 'url': row['url']});
      if (link == null) continue;
      final url = link.uri.toString();
      if (url.length > 1024 ||
          url.contains(key) ||
          url.contains(encodedKey) ||
          !seen.add(link.uri)) {
        continue;
      }
      records.add({
        'title': link.title,
        'url': url,
        'snippet': _plainText(row['snippet'], 300, key),
      });
      if (records.length == _maxRecords) break;
    }
    return records;
  }
}

class _ProviderSearchTool extends AgentTool {
  _ProviderSearchTool(ProviderWebSearch search, this._deepSeek)
    : super(
        spec: AgentToolSpec('web_search', '用公开关键词搜索网页，返回标题、链接和摘要。', {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'maxLength': _deepSeek ? _deepSeekQueryLimit : agentWebQueryLimit,
            },
          },
          'required': ['query'],
          'additionalProperties': false,
        }),
        source: AgentSourceKind.web,
        label: '正在搜索网页…',
        read: (args) async {
          final query = args['query'];
          if (query is! String) throw _invalidQuery;
          return search.search(query);
        },
      );

  final bool _deepSeek;

  @override
  bool accepts(Json? arguments) {
    if (!_deepSeek) return super.accepts(arguments);
    // The provider counts Unicode code points rather than UTF-16 code units.
    final query = arguments?['query'];
    return arguments?.length == 1 &&
        query is String &&
        _validQuery(query, deepSeek: true);
  }
}

bool _validQuery(String query, {required bool deepSeek}) =>
    query.trim().isNotEmpty &&
    (deepSeek
        ? query.runes.length <= _deepSeekQueryLimit
        : query.length <= agentWebQueryLimit);

Uri _endpoint(Uri base, _SearchApi api) {
  if (api == _SearchApi.deepSeek) return base.replace(pathSegments: api.path);
  final prefix = base.pathSegments.toList();
  while (prefix.isNotEmpty && prefix.last.isEmpty) {
    prefix.removeLast();
  }
  return base.replace(pathSegments: [...prefix, ...api.path]);
}

Iterable<Json> _responsesResults(Json body) {
  final output = _requiredObjects(body['output']);
  final searched = output.any((item) {
    final action = item['action'];
    return item['type'] == 'web_search_call' &&
        item['status'] == 'completed' &&
        (action == null || (action is Json && action['type'] == 'search'));
  });
  if (!searched) {
    throw const AgentFailure('当前模型未完成原生网页搜索。$_openAiFallback');
  }
  return _objectsFrom(
        output.where(
          (item) => item['type'] == 'message' && item['role'] == 'assistant',
        ),
        'content',
      )
      .where((block) => block['type'] == 'output_text')
      .expand((block) => _objects(block['annotations']))
      .where((annotation) => annotation['type'] == 'url_citation');
}

Iterable<Json> _chatResults(Json body) =>
    _requiredObjects(body['choices'])
        .map((choice) => choice['message'])
        .whereType<Json>()
        .where((message) => message['role'] == 'assistant')
        .expand((message) => _objects(message['annotations']))
        .where((annotation) => annotation['type'] == 'url_citation')
        .map((annotation) => annotation['url_citation'])
        .whereType<Json>();

Iterable<Json> _anthropicResults(Json body) {
  final blocks = _requiredObjects(body['content']);
  final results = blocks.where(
    (block) => block['type'] == 'web_search_tool_result',
  );
  if (results.isEmpty) throw const AgentFailure('模型未执行原生网页搜索。');
  final citedText = <Uri, Object?>{};
  for (final citation in _objectsFrom(
    blocks.where((block) => block['type'] == 'text'),
    'citations',
  )) {
    if (citation['type'] != 'web_search_result_location') continue;
    final link = AgentWebLink.fromJson(citation);
    if (link != null) citedText[link.uri] = citation['cited_text'];
  }
  return results.expand((block) {
    final content = block['content'];
    if (content is! List) throw const AgentFailure('模型网页搜索未成功，请检查网页搜索权限或稍后重试。');
    return content
        .whereType<Json>()
        .where((row) => row['type'] == 'web_search_result')
        .map((row) {
          final link = AgentWebLink.fromJson(row);
          return {
            'title': row['title'],
            'url': row['url'],
            'snippet': citedText[link?.uri],
          };
        });
  });
}

Iterable<Json> _requiredObjects(Object? value) {
  if (value is! List) throw const FormatException();
  return value.whereType<Json>();
}

Iterable<Json> _objects(Object? value) =>
    value is List ? value.whereType<Json>() : const [];

Iterable<Json> _objectsFrom(Iterable<Json> rows, String field) =>
    rows.expand((row) => _objects(row[field]));

String _plainText(Object? value, int limit, String key) {
  if (value is! String) return '';
  final text = value
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(key, '[已隐藏]')
      .trim();
  return String.fromCharCodes(text.runes.take(limit));
}
