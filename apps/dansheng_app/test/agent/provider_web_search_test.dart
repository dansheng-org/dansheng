// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/provider_web_search.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'fixture-model-key';
const _query = '公开校园公告';
const _url = 'https://news.example.test/announcement';
const _title = '公开公告';
const _citation = {'type': 'url_citation', 'title': _title, 'url': _url};
const _searchCall = {
  'type': 'web_search_call',
  'status': 'completed',
  'action': {'type': 'search', 'query': _query},
};

void main() {
  group('OpenAI', () {
    test('uses Responses on the configured prefix and projects evidenced citations', () async {
      final client = _Client(
        _responses(
          call: _searchCall,
          annotations: [
            _citation,
            _citation,
            {
              'type': 'url_citation',
              'title': '不安全链接',
              'url': 'http://example.test',
            },
            {
              'type': 'url_citation',
              'title': '凭据链接',
              'url': 'https://user:pass@example.test',
            },
            {
              'type': 'url_citation',
              'title': '密钥链接',
              'url': 'https://example.test/?token=$_key',
            },
            {
              'type': 'file_citation',
              'title': '文件链接',
              'url': 'https://example.test/file',
            },
          ],
        ),
      );
      final tool = _search(
        client,
        base: 'https://relay.example.test/custom/v1/',
      ).tool;
      expect(tool.spec.name, 'web_search');
      expect(tool.source, AgentSourceKind.web);
      expect(tool.spec.inputSchema['properties']['query']['maxLength'], 200);
      expect(tool.accepts({'query': _query, 'history': 'private'}), isFalse);
      final result = await tool.read({'query': ' $_query '});

      expect(client.urls, [
        Uri.parse('https://relay.example.test/custom/v1/responses'),
      ]);
      expect(client.request.headers.values['authorization'], 'Bearer $_key');
      expect(client.request.followRedirects, isFalse);
      expect(client.forceClosed, isTrue);
      expect(client.request.json, {
        'model': 'fixture-model',
        'input': _query,
        'instructions': isA<String>(),
        'tools': [
          {'type': 'web_search'},
        ],
        'tool_choice': 'required',
        'max_tool_calls': 1,
        'max_output_tokens': 1024,
        'store': false,
      });
      expect(result, {
        'source': 'OpenAI Web Search',
        'records': [
          {'title': _title, 'url': _url, 'snippet': ''},
        ],
      });
    });

    test(
      'requires both a completed search and a structured HTTPS citation',
      () async {
        const failedCall = {'type': 'web_search_call', 'status': 'failed'};
        const openPage = {
          'type': 'web_search_call',
          'status': 'completed',
          'action': {'type': 'open_page', 'url': _url},
        };
        for (final body in [
          _responses(annotations: [_citation]),
          _responses(call: failedCall, annotations: [_citation]),
          _responses(call: openPage, annotations: [_citation]),
          _responses(call: _searchCall),
        ]) {
          final client = _Client(body);
          await expectLater(
            _search(client).search(_query),
            throwsA(_failure(contains('Brave Search'))),
          );
          expect(client.urls, hasLength(1));
          expect(client.forceClosed, isTrue);
        }
      },
    );

    test(
      'only the exact supported chat search model uses Chat Completions',
      () async {
        final client = _Client({
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content':
                    'Link from generated text: https://other.example.test',
                'annotations': [
                  {'type': 'url_citation', 'url_citation': _citation},
                ],
              },
            },
          ],
        });
        final result = await _search(
          client,
          model: 'gpt-5-search-api',
        ).search(_query);
        expect(client.urls.single.path, '/v1/chat/completions');
        expect(client.request.json, {
          'model': 'gpt-5-search-api',
          'messages': [
            {'role': 'user', 'content': _query},
          ],
          'web_search_options': <String, Object?>{},
          'max_completion_tokens': 1024,
        });
        expect(result['records'], [
          {'title': _title, 'url': _url, 'snippet': ''},
        ]);

        final other = _Client(
          _responses(call: _searchCall, annotations: [_citation]),
        );
        await _search(other, model: 'gpt-5-search-api-custom').search(_query);
        expect(other.urls.single.path, '/v1/responses');
      },
    );

    test('reports unsupported API with Brave settings guidance and skips error body', () async {
      final client = _Client({
        'error': {'message': 'private $_key'},
      }, status: 404);
      await expectLater(
        _search(client).search(_query),
        throwsA(
          _failure(
            allOf(
              contains('设置'),
              contains('Brave Search'),
              isNot(contains('private')),
            ),
          ),
        ),
      );
      expect(client.urls, hasLength(1));
      expect(client.request.response.listened, isFalse);
      expect(client.forceClosed, isTrue);
    });
  });

  group('Anthropic', () {
    test('uses a single server search and extracts snippets from matching citations', () async {
      final client = _Client({
        'content': [
          {
            'type': 'server_tool_use',
            'name': 'web_search',
            'id': 'srvtoolu_test',
          },
          {
            'type': 'web_search_tool_result',
            'tool_use_id': 'srvtoolu_test',
            'content': [
              {
                'type': 'web_search_result',
                'title': _title,
                'url': _url,
                'encrypted_content': 'private cipher',
              },
            ],
          },
          {
            'type': 'text',
            'text': 'Unverified generated text',
            'citations': [
              {
                'type': 'web_search_result_location',
                'title': _title,
                'url': _url,
                'encrypted_index': 'private index',
                'cited_text': '<b>公告摘要</b> $_key',
              },
              {
                'type': 'web_search_result_location',
                'title': '关联不到的引用',
                'url': 'https://other.example.test',
                'cited_text': 'Other',
              },
            ],
          },
        ],
      });
      final result = await _search(
        client,
        provider: ModelProvider.anthropic,
        base: 'https://relay.example.test/anthropic/v1',
      ).search(_query);
      expect(client.urls.single.path, '/anthropic/v1/messages');
      expect(client.request.headers.values, containsPair('x-api-key', _key));
      expect(
        client.request.headers.values,
        containsPair('anthropic-version', '2023-06-01'),
      );
      expect(client.request.headers.values, isNot(contains('authorization')));
      expect(client.request.json, {
        'model': 'fixture-model',
        'system': isA<String>(),
        'messages': [
          {'role': 'user', 'content': _query},
        ],
        'tools': [
          {'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': 1},
        ],
        'max_tokens': 1024,
      });
      expect(result, {
        'source': 'Anthropic Web Search',
        'records': [
          {'title': _title, 'url': _url, 'snippet': '公告摘要 [已隐藏]'},
        ],
      });
    });

    test('rejects text-only replies and HTTP 200 tool errors', () async {
      for (final block in [
        {'type': 'text', 'text': 'Made up result at $_url'},
        {
          'type': 'web_search_tool_result',
          'content': {
            'type': 'web_search_tool_result_error',
            'error_code': 'too_many_requests',
            'message': 'private $_key',
          },
        },
      ]) {
        final client = _Client({
          'content': [block],
        });
        await expectLater(
          _search(client, provider: ModelProvider.anthropic).search(_query),
          throwsA(
            _failure(allOf(contains('网页搜索'), isNot(contains('private')))),
          ),
        );
        expect(client.urls, hasLength(1));
      }
    });
  });

  group('DeepSeek', () {
    for (final provider in ModelProvider.values) {
      test(
        'uses the official fixed origin and bearer auth for ${provider.name}',
        () async {
          final client = _Client({
            'results': [
              for (var index = 0; index < 7; index++)
                {
                  'title': '<b>$_title</b>',
                  'url': '$_url/$index',
                  'snippet': '简' * 400,
                  'summary': 'extra summary',
                  'content': 'extra page content',
                },
            ],
          });
          final tool = _search(
            client,
            provider: provider,
            base: 'https://api.deepseek.com:443/anthropic',
          ).tool;
          final query = '🌐' * 128;
          final overLimit = '🌐' * 129;
          expect(
            tool.spec.inputSchema['properties']['query']['maxLength'],
            128,
          );
          expect(tool.accepts({'query': query}), isTrue);
          expect(tool.accepts({'query': overLimit}), isFalse);
          await expectLater(
            tool.read({'query': overLimit}),
            throwsA(isA<AgentFailure>()),
          );
          expect(client.urls, isEmpty);
          final result = await tool.read({'query': query});
          expect(client.urls, [
            Uri.parse('https://api.deepseek.com/v1/tools/search'),
          ]);
          expect(
            client.request.headers.values,
            containsPair('authorization', 'Bearer $_key'),
          );
          expect(client.request.headers.values, isNot(contains('x-api-key')));
          expect(client.request.followRedirects, isFalse);
          expect(client.request.json, {
            'query': query,
            'count': 5,
            'need_content': false,
          });
          expect(result, {
            'source': 'DeepSeek Search',
            'records': [
              for (var index = 0; index < 5; index++)
                {'title': _title, 'url': '$_url/$index', 'snippet': '简' * 300},
            ],
          });
        },
      );
    }

    test(
      'does not select DeepSeek for a lookalike host or another port',
      () async {
        for (final base in [
          'https://api.deepseek.com.example.test/v1',
          'https://api.deepseek.com:8443/v1',
        ]) {
          final client = _Client(
            _responses(call: _searchCall, annotations: [_citation]),
          );
          final search = _search(client, base: base, model: 'deepseek-v4');
          expect(
            search.tool.spec.inputSchema['properties']['query']['maxLength'],
            200,
          );
          await search.search(_query);
          expect(client.urls.single.path, '/v1/responses');
        }
      },
    );

    test('accepts a legitimate empty results array', () async {
      final client = _Client({'results': []});
      expect(
        await _search(client, base: 'https://api.deepseek.com').search(_query),
        {'source': 'DeepSeek Search', 'records': []},
      );
    });
  });

  test(
    'rejects non-HTTPS or userinfo-bearing endpoints before opening a request',
    () async {
      for (final base in [
        'http://api.deepseek.com/v1',
        'https://private@api.deepseek.com',
      ]) {
        final client = _Client({});
        await expectLater(
          _search(client, base: base).search(_query),
          throwsA(_failure(isNot(contains('private')))),
        );
        expect(client.urls, isEmpty);
      }
    },
  );

  test(
    'blocks redirects and streamed responses beyond the byte limit',
    () async {
      final redirect = _Client({}, status: 302);
      await expectLater(
        _search(redirect).search(_query),
        throwsA(isA<AgentFailure>()),
      );
      expect(redirect.request.followRedirects, isFalse);
      expect(redirect.urls, hasLength(1));
      expect(redirect.forceClosed, isTrue);

      final big = _Client(
        {},
        chunks: List.filled(3, List.filled(256 * 1024, 32)),
      );
      await expectLater(
        _search(big).search(_query),
        throwsA(_failure(contains('响应过大'))),
      );
      expect(big.forceClosed, isTrue);
    },
  );
}

ProviderWebSearch _search(
  _Client client, {
  String? base,
  ModelProvider provider = ModelProvider.openAi,
  String model = 'fixture-model',
}) => ProviderWebSearch(
  AgentModelConfig(
    provider: provider,
    baseUrl: base == null
        ? AgentModelConfig.defaultBaseUrl(provider)
        : Uri.parse(base),
    model: model,
    apiKey: _key,
  ),
  createClient: () => client,
);

Matcher _failure(Matcher message) =>
    isA<AgentFailure>().having((e) => e.message, 'message', message);

Json _responses({Json? call, List<Json> annotations = const []}) => {
  'output': [
    ?call,
    {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {
          'type': 'output_text',
          'text': 'Unverified text at https://other.example.test',
          'annotations': annotations,
        },
      ],
    },
  ],
};

class _Client implements HttpClient {
  _Client(Json response, {int status = 200, List<List<int>>? chunks})
    : request = _Request(
        _Response(status, chunks ?? [utf8.encode(jsonEncode(response))]),
      );

  final _Request request;
  final urls = <Uri>[];
  bool forceClosed = false;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    urls.add(url);
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);

  final _Response response;
  final _bytes = <int>[];
  Json get json => jsonDecode(utf8.decode(_bytes)) as Json;

  @override
  final _Headers headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  int contentLength = -1;

  @override
  void add(List<int> data) => _bytes.addAll(data);

  @override
  Future<HttpClientResponse> close() async => response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, List<List<int>> chunks)
    : _body = Stream.fromIterable(chunks);

  final Stream<List<int>> _body;
  bool listened = false;

  @override
  final int statusCode;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listened = true;
    return _body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final values = <String, Object>{};

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
