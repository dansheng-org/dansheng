// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/model_catalog.dart';
import 'package:dansheng_app/ui/campus/agent/agent_chat_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'catalog-fixture';
final _prefix = Uri.parse('https://models.example.test/proxy%2Ftenant/v1//');

void main() {
  group('catalog transport', _testCatalog);
  group('catalog settings', _testSettings);
}

void _testCatalog() {
  test('OpenAI preserves the prefix and uses bearer authentication', () async {
    final client = _Client(
      (_) async => _Response({
        'data': [
          {'id': 'first'},
          {'id': 'second', 'name': 'Second Model'},
          {'id': 'second'},
          {'id': '  '},
          {'id': 'unsafe\u202e-id'},
          {'id': 'unsafe\n-id'},
          {'id': false},
          null,
        ],
        'has_more': true,
        'last_id': 'ignored',
      }),
    );

    final models = await _load(client, ModelProvider.openAi);

    final request = client.requests.single;
    expect(
      request.url.toString(),
      'https://models.example.test/proxy%2Ftenant/v1/models',
    );
    expect(request.headers.value('authorization'), 'Bearer $_key');
    expect(request.headers.value('accept'), 'application/json');
    expect(request.headers.value('x-api-key'), isNull);
    expect(request.followRedirects, isFalse);
    expect(client.forceClosed, isTrue);
    expect(models.map((model) => model.id), ['first', 'second']);
    expect(models.map((model) => model.label), [null, 'Second Model']);
  });

  test(
    'Responses accepts a full endpoint and shares the model catalog',
    () async {
      final client = _Client(
        (_) async => _Response({
          'data': [
            {'id': 'deepseek-flash'},
          ],
        }),
      );
      final models = await ModelCatalog(client: client).load(
        provider: ModelProvider.openAiResponses,
        baseUrl: Uri.parse('https://api.deepseek.com/responses/'),
        apiKey: _key,
      );
      final request = client.requests.single;
      expect(request.url, Uri.parse('https://api.deepseek.com/models'));
      expect(request.headers.value('authorization'), 'Bearer $_key');
      expect(models.single.id, 'deepseek-flash');
    },
  );

  test(
    'display labels are sanitized and capped at Unicode code points',
    () async {
      final label = List.filled(130, '😀').join();
      final expected = List.filled(113, '😀').join();
      final client = _Client(
        (_) async => _Response({
          'data': [
            {'id': 'first', 'display_name': 'Family\n$label'},
            {'id': 'second', 'display_name': '\u202e\u0085'},
          ],
        }),
      );

      final models = await _load(client, ModelProvider.openAi);

      expect(models.first.label, 'Family $expected');
      expect(models.last.label, isNull);
    },
  );

  test(
    'Anthropic follows encoded cursors and stops on a repeated cursor',
    () async {
      const cursor = 'claude+cursor/?';
      final client = _Client(
        (page) async => _Response({
          'data': [
            {'id': 'claude-$page', 'display_name': 'Claude $page'},
          ],
          'has_more': true,
          'last_id': cursor,
        }),
      );

      final models = await _load(client, ModelProvider.anthropic);

      expect(models.map((model) => model.label), ['Claude 0', 'Claude 1']);
      expect(client.requests.first.url.hasQuery, isFalse);
      expect(client.requests.last.url.queryParameters, {'after_id': cursor});
      for (final request in client.requests) {
        expect(request.headers.value('x-api-key'), _key);
        expect(request.headers.value('anthropic-version'), '2023-06-01');
        expect(request.headers.value('authorization'), isNull);
        expect(request.followRedirects, isFalse);
      }
    },
  );

  test('Anthropic makes at most five requests for distinct cursors', () async {
    final client = _Client(
      (page) async => _Response({
        'data': [
          {'id': 'claude-$page'},
        ],
        'has_more': true,
        'last_id': 'claude-$page',
      }),
    );

    final models = await _load(client, ModelProvider.anthropic);

    expect(models, hasLength(5));
    expect(client.requests, hasLength(5));
    expect(client.requests.last.url.queryParameters, {'after_id': 'claude-3'});
  });

  test(
    'cancellation closes the client and prevents additional pages',
    () async {
      final reply = Completer<HttpClientResponse>();
      final client = _Client((_) => reply.future);
      final catalog = ModelCatalog(client: client);
      final load = catalog.load(
        provider: ModelProvider.anthropic,
        baseUrl: _prefix,
        apiKey: _key,
      );
      final cancelled = expectLater(load, throwsA(isA<AgentFailure>()));
      await client.requestSent.future;
      catalog.close();
      await cancelled;
      reply.complete(
        _Response({'data': [], 'has_more': true, 'last_id': 'next'}),
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.forceClosed, isTrue);
      expect(client.requests, hasLength(1));
    },
  );

  test('redirects and malformed lists produce sanitized failures', () async {
    for (final response in [
      _Response({'location': 'https://other.example.test'}, statusCode: 302),
      _Response({'error': _key}),
    ]) {
      final client = _Client((_) async => response);
      await expectLater(
        _load(client, ModelProvider.openAi),
        throwsA(
          isA<AgentFailure>().having(
            (failure) => failure.message,
            'message',
            isNot(contains(_key)),
          ),
        ),
      );
      expect(client.requests.single.followRedirects, isFalse);
      expect(client.forceClosed, isTrue);
    }
  });
}

Future<List<ModelCatalogEntry>> _load(_Client client, ModelProvider provider) =>
    ModelCatalog(client: client)
        .load(provider: provider, baseUrl: _prefix, apiKey: _key);

class _Client implements HttpClient {
  _Client(this.respond);

  final Future<HttpClientResponse> Function(int page) respond;
  final requests = <_Request>[];
  final requestSent = Completer<void>();
  bool forceClosed = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final page = requests.length;
    final request = _Request(url, () {
      if (!requestSent.isCompleted) requestSent.complete();
      return respond(page);
    });
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => forceClosed = force;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.url, this.respond);

  final Uri url;
  final Future<HttpClientResponse> Function() respond;

  @override
  final headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() => respond();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final _values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(Json body, {this.statusCode = 200})
    : super(Stream.value(utf8.encode(jsonEncode(body))));

  @override
  final int statusCode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _firstAddress = 'https://first.example.test/api/v1';
const _secondAddress = 'https://second.example.test/api/v1';
const _braveField = 'Brave Search API 密钥（可选）';
const _debounceWindow = Duration(milliseconds: 500);

void _testSettings() {
  testWidgets(
    'loads with a retained key, refreshes, and picks by ID or label',
    (tester) async {
      final calls = <({ModelProvider provider, Uri baseUrl, String apiKey})>[];
      final pending = Completer<List<ModelCatalogEntry>>();
      await _mount(
        tester,
        config: _savedConfig(),
        load: ({required provider, required baseUrl, required apiKey}) {
          calls.add((provider: provider, baseUrl: baseUrl, apiKey: apiKey));
          if (calls.length == 1) return pending.future;
          return Future.value(const [
            ModelCatalogEntry('model-a'),
            ModelCatalogEntry('model-b', label: 'Second Variant'),
          ]);
        },
      );

      await tester.enterText(
        _field('API 地址前缀'),
        'https://FIRST.example.test:443/api/v1/',
      );
      await tester.pump(_debounceWindow);
      await tester.pumpAndSettle();
      expect(find.text('正在读取模型列表…'), findsOneWidget);
      expect(calls.single, (
        provider: ModelProvider.openAi,
        baseUrl: Uri.parse(_firstAddress),
        apiKey: 'saved-model-key',
      ));

      await tester.tap(find.text('刷新模型列表'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      pending.complete(const [ModelCatalogEntry('obsolete')]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('选择模型'));
      await tester.pumpAndSettle();
      final query = _field('搜索模型标识或名称');
      await tester.enterText(query, 'MODEL-A');
      await tester.pump();
      expect(find.text('model-a'), findsOneWidget);
      expect(find.text('Second Variant'), findsNothing);
      expect(find.text('obsolete'), findsNothing);
      await tester.enterText(query, 'variant');
      await tester.pump();
      expect(find.text('model-a'), findsNothing);
      expect(find.text('model-b'), findsOneWidget);
      await tester.tap(find.text('Second Variant'));
      await tester.pumpAndSettle();
      expect(_text(tester, '模型标识'), 'model-b');

      final settings = ModalRoute.of(
        tester.element(find.byType(AgentChatSettings)),
      )!;
      await tester.tap(find.text('选择模型'));
      await tester.pumpAndSettle();
      settings.navigator!.removeRoute(settings);
      await tester.pumpAndSettle();
      expect(query, findsNothing);
      expect(find.text('打开设置'), findsOneWidget);
    },
  );

  testWidgets('debounces edits and never moves a draft key to a new endpoint', (
    tester,
  ) async {
    final keys = <String>[];
    final urls = <Uri>[];
    final previous = Completer<List<ModelCatalogEntry>>();
    await _mount(
      tester,
      load: ({required provider, required baseUrl, required apiKey}) {
        keys.add(apiKey);
        urls.add(baseUrl);
        if (keys.length == 1) return previous.future;
        return Future.value(const [ModelCatalogEntry('new-model')]);
      },
    );

    final endpoint = _field('API 地址前缀');
    final key = _field('API 密钥');
    await tester.enterText(endpoint, _firstAddress);
    await tester.enterText(key, 'first');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(key, 'first-final');
    await tester.pump(const Duration(milliseconds: 300));
    expect(keys, isEmpty);
    await tester.pump(_debounceWindow);
    expect(keys, ['first-final']);

    await tester.enterText(endpoint, _secondAddress);
    await tester.pump(_debounceWindow);
    expect(_text(tester, 'API 密钥'), isEmpty);
    expect(keys, ['first-final']);
    await tester.enterText(key, 'second-final');
    await tester.pump(_debounceWindow);
    expect(keys, ['first-final', 'second-final']);
    expect(urls.map((url) => url.toString()), [_firstAddress, _secondAddress]);

    previous.complete(const [
      ModelCatalogEntry('old-a'),
      ModelCatalogEntry('old-b'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('已读取 1 个模型。'), findsOneWidget);
    await tester.tap(find.text('选择模型'));
    await tester.pumpAndSettle();
    expect(find.text('new-model'), findsOneWidget);
    expect(find.text('old-a'), findsNothing);
  });

  testWidgets('a failed list still allows saving a manual model ID', (
    tester,
  ) async {
    AgentModelConfig? saved;
    await _mount(
      tester,
      config: _savedConfig(),
      load: ({required provider, required baseUrl, required apiKey}) async {
        throw StateError('fixture error containing $apiKey');
      },
      onSave: (config) => saved = config,
    );
    await tester.pump(_debounceWindow);
    await tester.pumpAndSettle();
    expect(find.textContaining('可手动输入模型标识'), findsOneWidget);
    expect(find.textContaining('saved-model-key'), findsNothing);
    await tester.enterText(_field('模型标识'), 'manual-id');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(saved?.model, 'manual-id');
  });

  testWidgets('Brave Search key is obscured, retained, replaced, and removed', (
    tester,
  ) async {
    final saved = <AgentModelConfig>[];
    await _mount(
      tester,
      config: _savedConfig(searchKey: 'saved-search-key'),
      load: ({required provider, required baseUrl, required apiKey}) async =>
          [],
      onSave: saved.add,
    );
    final field = _field(_braveField);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(_text(tester, _braveField), isEmpty);
    expect(
      find.text('网页搜索默认由模型服务执行。填写 Brave 密钥后改用 Brave Search。'),
      findsOneWidget,
    );
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(saved.single.searchApiKey, 'saved-search-key');

    await _openSettings(tester);
    await tester.enterText(field, 'replacement-search-key');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(saved.last.searchApiKey, 'replacement-search-key');

    await _openSettings(tester);
    await tester.tap(find.byTooltip('移除已保存的 Brave Search 密钥'));
    await tester.pump();
    expect(find.text('保存配置时移除密钥'), findsOneWidget);
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(3));
    expect(saved.last.searchApiKey, isNull);
    expect(saved.last.apiKey, 'saved-model-key');
  });
}

AgentModelConfig _savedConfig({String? searchKey}) => AgentModelConfig(
  provider: ModelProvider.openAi,
  baseUrl: Uri.parse(_firstAddress),
  model: 'previous-model',
  apiKey: 'saved-model-key',
  searchApiKey: searchKey,
);

Future<void> _mount(
  WidgetTester tester, {
  AgentModelConfig? config,
  required ModelCatalogLoader load,
  void Function(AgentModelConfig)? onSave,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 860);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  var current = config;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => AgentChatSettings(
                  config: current,
                  canClear: current != null,
                  loadModels: load,
                  onSave: (config) async {
                    current = config;
                    onSave?.call(config);
                  },
                  onClear: () async {},
                ),
              ),
            ),
            child: const Text('打开设置'),
          ),
        ),
      ),
    ),
  );
  await _openSettings(tester);
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;
