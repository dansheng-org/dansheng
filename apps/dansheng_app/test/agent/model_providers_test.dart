// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/agent/model_providers.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = 'test-key-do-not-disclose';
const _user = AgentMessage.user('Find my courses.');
const _pdfHeader = 'JVBERi0xLjQK';
// Minimal file headers for the mocked transport.
const _png = AgentAttachment(
  name: 'course.png',
  mimeType: 'image/png',
  base64Data: 'iVBORw0KGgo=',
);
const _pdf = AgentAttachment(
  name: 'syllabus.pdf',
  mimeType: 'application/pdf',
  base64Data: _pdfHeader,
);
const _attachedUser = AgentMessage.user(
  'Find my courses.',
  attachments: [_png],
);
const _tool = AgentToolSpec('courses', 'List courses', {'type': 'object'});
const _done = 'data: [DONE]\n\n';
const _messageProviders = [ModelProvider.openAi, ModelProvider.anthropic];

void main() {
  group('Responses', () {
    test(
      'replays exact current output in order and folds earlier dialogue',
      () async {
        final thinking = {
          'type': 'reasoning',
          'id': 'rs-1',
          'summary': [],
          'content': [
            {'type': 'reasoning_text', 'text': 'private reasoning'},
          ],
        };
        final visible = _responsesMessage('我先查课程。');
        final first = _responsesCall('call-first', '{ "page": 1 }');
        final second = _responsesCall('call-second', '{invalid');
        final output = [thinking, visible, first, second];
        final nextCall = _responsesCall('call-next', '{}');
        final client = _Client([
          _Response.sse(
            '${_event('response.reasoning_text.delta', {'delta': 'private'})}'
            '${_responsesItemDone(0, thinking)}'
            '${_responsesDelta('我先', output: 1)}'
            '${_responsesDelta('查课程。', output: 1)}'
            '${_responsesItemDone(1, visible)}'
            '${_responsesItemDone(3, second)}'
            '${_responsesItemDone(2, first)}'
            '${_responsesTerminal(output)}',
          ),
          _Response.sse(_responsesTerminal([nextCall])),
          _Response.sse(_responsesTerminal([_responsesMessage('完成')])),
          _Response.sse(_responsesTerminal([_responsesMessage('新问题')])),
        ]);
        final model = _model(
          ModelProvider.openAiResponses,
          client,
          base: 'https://api.deepseek.com/v1/',
          name: 'deepseek-flash',
          effort: AgentReasoningEffort.high,
        );
        addTearDown(model.close);
        const oldUser = AgentMessage.user('older question');
        const oldIntermediate = AgentMessage.assistant('older interim', [
          AgentToolCall('old-call', 'courses', {}),
        ]);
        const oldResult = AgentMessage.tool(
          'old-call',
          'old structured result',
        );
        const oldAnswer = AgentMessage.assistant('older visible answer');
        final messages = [
          oldUser,
          oldIntermediate,
          oldResult,
          oldAnswer,
          _user,
        ];
        final deltas = <String>[];

        Future<AgentMessage> complete([
          List<AgentToolSpec> tools = const [_tool],
        ]) => model.complete(
          messages: [...messages],
          tools: tools,
          onText: deltas.add,
        );

        final reply = await complete();
        expect(deltas, ['我先', '查课程。']);
        expect(reply.text, '我先查课程。');
        expect(reply.calls.map((call) => call.id), [
          'call-first',
          'call-second',
        ]);
        expect(reply.calls.first.arguments, {'page': 1});
        expect(reply.calls.last.arguments, isNull);
        final initial = client.requests.first;
        expect(
          client.urls.first,
          Uri.parse('https://api.deepseek.com/responses'),
        );
        expect(initial.followRedirects, isFalse);
        expect(initial.headers.value('authorization'), 'Bearer $_key');
        expect(initial.headers.value('accept'), 'text/event-stream');
        expect(initial.json, {
          'model': 'deepseek-flash',
          'stream': true,
          'instructions': agentSystemPrompt,
          'max_output_tokens': 32768,
          'reasoning': {'effort': 'max'},
          'input': [
            {
              'type': 'message',
              'role': 'user',
              'content': [
                {
                  'type': 'input_text',
                  'text': allOf(
                    contains('older question'),
                    contains('older interim'),
                    contains('older visible answer'),
                    contains(_user.text),
                    isNot(contains('old structured result')),
                  ),
                },
              ],
            },
          ],
          'tools': [
            {
              'type': 'function',
              'name': _tool.name,
              'description': _tool.description,
              'parameters': _tool.inputSchema,
            },
          ],
        });

        messages.addAll([
          reply,
          const AgentMessage.tool('call-first', '{"ok":true}'),
          const AgentMessage.tool('call-second', '{"error":"invalid"}'),
        ]);
        final continuation = await complete();
        final secondInput = client.requests[1].json['input'] as List<dynamic>;
        expect(secondInput, [
          initial.json['input'][0],
          ...output,
          {
            'type': 'function_call_output',
            'call_id': 'call-first',
            'output': '{"ok":true}',
          },
          {
            'type': 'function_call_output',
            'call_id': 'call-second',
            'output': '{"error":"invalid"}',
          },
        ]);
        messages.addAll([
          continuation,
          const AgentMessage.tool('call-next', '{}'),
          _attachedUser,
        ]);
        final answer = await complete([]);
        final thirdInput = client.requests[2].json['input'] as List<dynamic>;
        expect(thirdInput.take(secondInput.length), secondInput);
        expect(thirdInput[secondInput.length], nextCall);
        expect(
          thirdInput.last['content'],
          contains(
            equals({
              'type': 'input_image',
              'image_url': 'data:image/png;base64,${_png.base64Data}',
              'detail': 'auto',
            }),
          ),
        );
        expect(answer.text, '完成');

        messages.addAll([answer, const AgentMessage.user('current follow-up')]);
        await complete();
        final nextWire = jsonEncode(client.requests[3].json['input']);
        expect(nextWire, contains('current follow-up'));
        expect(nextWire, contains('完成'));
        expect(nextWire, isNot(contains('private reasoning')));
        expect(nextWire, isNot(contains('function_call')));
        expect(deltas, ['我先', '查课程。', '完成', '新问题']);
      },
    );

    for (final (effort, level) in [
      (AgentReasoningEffort.defaultEffort, null),
      (AgentReasoningEffort.low, 'low'),
      (AgentReasoningEffort.medium, 'high'),
    ]) {
      test('uses DeepSeek Responses effort ${effort.name}', () async {
        final client = _Client([_Response.sse(_responsesTerminal([]))]);
        final model = _model(
          ModelProvider.openAiResponses,
          client,
          base: 'https://api.deepseek.com/responses',
          name: 'deepseek-v4-pro',
          effort: effort,
        );
        addTearDown(model.close);
        await _complete(model);
        expect(client.urls.single.path, '/responses');
        final json = client.requests.single.json;
        expect(json['reasoning'], level == null ? null : {'effort': level});
        expect(json['max_output_tokens'], 32768);
      });
    }

    test('uploads DeepSeek PDFs once and sends the actual file ID', () async {
      final client = _Client([
        _Response.json('{"id":"file-api-test-pdf"}'),
        _Response.sse(_responsesTerminal([_responsesMessage('Read.')])),
        _Response.sse(_responsesTerminal([_responsesMessage('Read again.')])),
      ]);
      final model = _model(
        ModelProvider.openAiResponses,
        client,
        base: 'https://api.deepseek.com',
        name: 'deepseek-flash',
      );
      addTearDown(model.close);
      const attachment = AgentAttachment(
        name: 'notes.txt',
        mimeType: 'text/plain',
        base64Data: '',
        text: 'synthetic notes',
      );
      const message = AgentMessage.user(
        '',
        attachments: [_pdf, attachment, _png],
      );
      for (var index = 0; index < 2; index++) {
        await model.complete(messages: [message], tools: [], onText: (_) {});
      }
      expect(client.urls.map((url) => url.path), [
        '/files',
        '/responses',
        '/responses',
      ]);
      final upload = client.requests.first;
      expect(upload.headers.value('authorization'), 'Bearer $_key');
      expect(utf8.decode(upload.body), contains('rich_layout_recognition'));
      expect(utf8.decode(upload.body), contains('%PDF-'));
      for (final request in client.requests.skip(1)) {
        expect(request.json['input'][0]['content'], [
          {'type': 'input_file', 'file_id': 'file-api-test-pdf'},
          {'type': 'input_text', 'text': '文件数据 "notes.txt"\nsynthetic notes'},
          {
            'type': 'input_image',
            'image_url': 'data:image/png;base64,${_png.base64Data}',
            'detail': 'auto',
          },
        ]);
      }
    });

    test('streams the entire cached PDF with its original filename', () async {
      final client = _Client([
        _Response.json('{"id":"file-api-cached-pdf"}'),
        _Response.sse(_responsesTerminal([_responsesMessage('Read.')])),
      ]);
      final model = _model(
        ModelProvider.openAiResponses,
        client,
        base: 'https://api.deepseek.com',
        name: 'deepseek-flash',
      );
      addTearDown(model.close);
      final pdf = Uint8List(agentMaxCampusPdfBytes + 1);
      pdf.setAll(0, ascii.encode('%PDF-1.7\n'));
      pdf.last = 0x5a;
      final attachment = AgentAttachment.cachedPdf(
        name: '课程图表.pdf',
        size: pdf.length,
        openRead: () => Stream.fromIterable([
          Uint8List.sublistView(pdf, 0, 3),
          Uint8List.sublistView(pdf, 3),
        ]),
      );
      await model.complete(
        messages: [
          AgentMessage.user('读图。', attachments: [attachment]),
        ],
        tools: [],
        onText: (_) {},
      );
      final upload = client.requests.first;
      final boundary = upload.headers.contentType!.parameters['boundary'];
      final suffix = ascii.encode('\r\n--$boundary--\r\n');
      final body = upload.body;
      final start = body.length - pdf.length - suffix.length;
      final prefix = utf8.decode(Uint8List.sublistView(body, 0, start));
      expect(prefix, contains('filename="课程图表.pdf"'));
      expect(prefix, contains('rich_layout_recognition'));
      expect(Uint8List.sublistView(body, start, start + pdf.length), pdf);
      expect(Uint8List.sublistView(body, start + pdf.length), suffix);
      expect(upload.contentLength, body.length);
      expect(client.requests.last.json['input'][0]['content'][1], {
        'type': 'input_file',
        'file_id': 'file-api-cached-pdf',
      });
    });

    test('streams text immediately and returns at the terminal event', () async {
      final stream = StreamController<List<int>>();
      final client = _Client([_Response(stream.stream)]);
      final model = _model(ModelProvider.openAiResponses, client);
      addTearDown(model.close);
      final streamed = Completer<void>();
      final deltas = <String>[];
      final result = model.complete(
        messages: [_user],
        tools: [],
        onText: (delta) {
          deltas.add(delta);
          if (!streamed.isCompleted) streamed.complete();
        },
      );
      await client.requestSent.future;
      stream.add(utf8.encode(_responsesDelta('first')));
      await streamed.future;
      expect(deltas, ['first']);
      stream.add(
        utf8.encode(
          '${_event('response.output_text.done', {'output_index': 0, 'content_index': 0, 'text': 'first'})}'
          '${_responsesTerminal([_responsesMessage('first')])}',
        ),
      );
      try {
        expect((await result).text, 'first');
        expect(deltas, ['first']);
      } finally {
        await stream.close();
      }
    });

    test('reports incomplete visible output and discards unfinished calls', () async {
      final client = _Client([
        _Response.sse(
          '${_responsesDelta('First')}'
          '${_responsesDelta('Later', output: 1)}'
          '${_responsesTerminal([_responsesMessage('First finished'), _responsesMessage('Later'), _responsesCall('partial-call', '{')], status: 'incomplete', reason: 'max_output_tokens')}',
        ),
      ]);
      final model = _model(ModelProvider.openAiResponses, client);
      addTearDown(model.close);
      final deltas = <String>[];
      final reply = await model.complete(
        messages: [_user],
        tools: [_tool],
        onText: deltas.add,
      );
      expect(reply.outputTruncated, isTrue);
      expect(reply.calls, isEmpty);
      expect(reply.text, 'First finishedLater');
      expect(deltas, ['First', ' finishedLater']);
    });

    for (final (wire, failure) in [
      (
        _event('error', {'code': 'rate_limit_exceeded', 'message': _key}),
        '速率或配额',
      ),
      (
        _responsesTerminal(
          [],
          status: 'failed',
          error: {'code': 'server_error', 'message': _key},
        ),
        '繁忙',
      ),
      (
        _responsesTerminal([], status: 'incomplete', reason: 'content_filter'),
        '过滤',
      ),
      (_responsesDelta('partial'), '完整结束前中断'),
      (_done, '完整结束前中断'),
    ]) {
      test(
        'handles early or terminal Responses error $failure (${wire.length})',
        () async {
          final model = _model(
            ModelProvider.openAiResponses,
            _Client([_Response.sse(wire)]),
          );
          addTearDown(model.close);
          await expectLater(_complete(model), _failsWith(failure));
        },
      );
    }
  });

  test(
    'OpenAI streams UTF-8 and indexed calls, then replays tool outputs',
    () async {
      final client = _Client([
        _Response.sse(
          ': keepalive\r\n\r\n'
          'data: {"choices": [\r\n'
          'data: {"index":0,"delta":{"content":"课程"}}]}\r\n\r\n'
          '${_chat({
            'tool_calls': [
              {
                'index': 1,
                'id': 'call_b',
                'type': 'function',
                'function': {'name': 'courses', 'arguments': '[]'},
              },
              {
                'index': 0,
                'id': 'call_a',
                'type': 'function',
                'function': {'name': 'courses', 'arguments': '{"term":'},
              },
            ],
          })}'
          '${_chat({
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': '"fall"}'},
              },
            ],
          })}'
          '${_chat({}, finish: 'tool_calls')}'
          'data: {"choices":[],"usage":{"completion_tokens":10}}\n\n'
          '$_done',
        ),
        _Response.sse('${_chat({'content': 'Done.'}, finish: 'stop')}$_done'),
      ]);
      final model = _model(ModelProvider.openAi, client);
      addTearDown(model.close);
      final deltas = <String>[];
      final reply = await model.complete(
        messages: [_attachedUser],
        tools: [_tool],
        onText: deltas.add,
      );
      expect(deltas, ['课程']);
      expect(reply.text, '课程');
      expect(reply.calls.map((call) => call.id), ['call_a', 'call_b']);
      expect(reply.calls.first.name, 'courses');
      expect(reply.calls.first.arguments, {'term': 'fall'});
      expect(reply.calls.last.arguments, isNull);
      expect(
        client.urls.single,
        Uri.parse('https://provider.invalid/prefix/v1/chat/completions'),
      );
      final request = client.requests.single;
      expect(request.followRedirects, isFalse);
      expect(request.headers.value('authorization'), 'Bearer $_key');
      expect(request.headers.value('x-api-key'), isNull);
      expect(request.headers.value('accept'), 'text/event-stream');
      expect(request.json, containsPair('stream', true));
      expect(request.json, containsPair('max_completion_tokens', 4096));
      expect(request.json, isNot(contains('reasoning_effort')));
      expect(request.json['messages'], [
        {'role': 'system', 'content': agentSystemPrompt},
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': _attachedUser.text},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,${_png.base64Data}'},
            },
          ],
        },
      ]);
      expect(request.json['tools'], [
        {
          'type': 'function',
          'function': {
            'name': 'courses',
            'description': 'List courses',
            'parameters': _tool.inputSchema,
          },
        },
      ]);

      final finalReply = await model.complete(
        messages: [
          _attachedUser,
          reply,
          const AgentMessage.tool('call_a', '[]'),
          const AgentMessage.tool('call_b', 'Invalid arguments'),
        ],
        tools: [],
        onText: (_) {},
      );
      expect(finalReply.text, 'Done.');
      final replay = client.requests.last.json;
      expect(replay.containsKey('tools'), isFalse);
      final replayMessages = replay['messages'] as List<Object?>;
      expect(replayMessages.take(2), request.json['messages']);
      expect(replayMessages.skip(2), [
        {
          'role': 'assistant',
          'content': '课程',
          'tool_calls': [
            {
              'id': 'call_a',
              'type': 'function',
              'function': {'name': 'courses', 'arguments': '{"term":"fall"}'},
            },
            {
              'id': 'call_b',
              'type': 'function',
              'function': {'name': 'courses', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_a', 'content': '[]'},
        {
          'role': 'tool',
          'tool_call_id': 'call_b',
          'content': 'Invalid arguments',
        },
      ]);
    },
  );

  test('Anthropic streams text and tool blocks, then groups results before text', () async {
    final client = _Client([
      _Response.sse(
        '$_messageStart'
        '${_blockStart(0, {'type': 'thinking', 'thinking': ''})}'
        '${_blockDelta(0, {'type': 'thinking_delta', 'thinking': 'Internal summary'})}'
        '${_blockDelta(0, {'type': 'signature_delta', 'signature': 'test-signature'})}'
        '${_blockStop(0)}'
        '${_blockStart(1, {'type': 'text', 'text': 'Check'})}'
        '${_event('ping')}'
        '${_event('future_event')}'
        '${_blockDelta(1, {'type': 'text_delta', 'text': 'ing.'})}'
        '${_blockStop(1)}'
        '${_blockStart(2, {'type': 'tool_use', 'id': 'tool_a', 'name': 'courses', 'input': <String, dynamic>{}})}'
        '${_blockDelta(2, {'type': 'input_json_delta', 'partial_json': '{"term":'})}'
        '${_blockDelta(2, {'type': 'input_json_delta', 'partial_json': '"fall"}'})}'
        '${_blockStop(2)}'
        '${_blockStart(3, {'type': 'redacted_thinking', 'data': 'opaque-test-data'})}'
        '${_blockStop(3)}'
        '${_blockStart(4, {'type': 'tool_use', 'id': 'tool_b', 'name': 'courses', 'input': <String, dynamic>{}})}'
        '${_blockDelta(4, {'type': 'input_json_delta', 'partial_json': ''})}'
        '${_blockStop(4)}'
        '${_blockStart(5, {'type': 'text', 'text': ' Ready.'})}'
        '${_blockStop(5)}${_anthropicFinish('tool_use')}${_event('message_stop')}',
      ),
      _Response.sse(
        '$_messageStart${_anthropicFinish('end_turn')}${_event('message_stop')}',
      ),
    ]);
    final model = _model(ModelProvider.anthropic, client);
    addTearDown(model.close);
    final deltas = <String>[];
    final reply = await model.complete(
      messages: [_attachedUser],
      tools: [_tool],
      onText: deltas.add,
    );
    expect(deltas, ['Check', 'ing.', ' Ready.']);
    expect(reply.text, 'Checking. Ready.');
    expect(reply.calls.map((call) => call.id), ['tool_a', 'tool_b']);
    expect(reply.calls.map((call) => call.arguments), [
      {'term': 'fall'},
      <String, dynamic>{},
    ]);
    expect(
      client.urls.single,
      Uri.parse('https://provider.invalid/prefix/v1/messages'),
    );
    final request = client.requests.single;
    expect(request.followRedirects, isFalse);
    expect(request.headers.value('x-api-key'), _key);
    expect(request.headers.value('anthropic-version'), '2023-06-01');
    expect(request.headers.value('authorization'), isNull);
    expect(request.json, containsPair('system', agentSystemPrompt));
    expect(request.json, containsPair('max_tokens', 4096));
    expect(request.json, isNot(contains('thinking')));
    expect(request.json['tools'], [
      {
        'name': 'courses',
        'description': 'List courses',
        'input_schema': _tool.inputSchema,
      },
    ]);

    await model.complete(
      messages: [
        _attachedUser,
        reply,
        const AgentMessage.tool('tool_a', '[]'),
        const AgentMessage.tool('tool_b', 'More courses'),
        const AgentMessage.user(
          'Include current courses only.',
          attachments: [_pdf],
        ),
      ],
      tools: [_tool],
      onText: (_) {},
    );
    expect(client.requests.last.json['messages'], [
      (request.json['messages'] as List<Object?>).single,
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'thinking',
            'thinking': 'Internal summary',
            'signature': 'test-signature',
          },
          {'type': 'text', 'text': 'Checking.'},
          {
            'type': 'tool_use',
            'id': 'tool_a',
            'name': 'courses',
            'input': {'term': 'fall'},
          },
          {'type': 'redacted_thinking', 'data': 'opaque-test-data'},
          {
            'type': 'tool_use',
            'id': 'tool_b',
            'name': 'courses',
            'input': <String, dynamic>{},
          },
          {'type': 'text', 'text': ' Ready.'},
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'tool_a', 'content': '[]'},
          {
            'type': 'tool_result',
            'tool_use_id': 'tool_b',
            'content': 'More courses',
          },
          {'type': 'text', 'text': 'Include current courses only.'},
          {
            'type': 'document',
            'title': _pdf.name,
            'source': {
              'type': 'base64',
              'media_type': 'application/pdf',
              'data': _pdf.base64Data,
            },
          },
        ],
      },
    ]);
  });

  group('user attachments', () {
    const jpeg = AgentAttachment(
      name: 'photo.jpg',
      mimeType: 'image/jpeg',
      base64Data: '/9j/',
    );
    const webp = AgentAttachment(
      name: 'diagram.webp',
      mimeType: 'image/webp',
      base64Data: 'UklGRgAAAABXRUJQ',
    );
    const notes = AgentAttachment(
      name: 'notes.txt',
      mimeType: 'text/plain',
      base64Data: 'bGluZSAxCmxpbmUgMg==',
      text: 'line 1\nline 2',
    );
    const textFiles = [
      (name: 'readme.md', mimeType: 'text/markdown', text: '# Notes'),
      (name: 'courses.csv', mimeType: 'text/csv', text: 'id,title'),
      (name: 'courses.json', mimeType: 'application/json', text: '[]'),
    ];

    test(
      'OpenAI sends a first-turn TXT attachment as string content',
      () async {
        final client = _Client([
          _Response.sse('${_chat({}, finish: 'stop')}$_done'),
        ]);
        final model = _model(ModelProvider.openAi, client);
        addTearDown(model.close);

        await model.complete(
          messages: [
            const AgentMessage.user('Read the notes.', attachments: [notes]),
          ],
          tools: [],
          onText: (_) {},
        );

        expect(client.requests.single.json['messages'], [
          {'role': 'system', 'content': agentSystemPrompt},
          {
            'role': 'user',
            'content': 'Read the notes.\n\n文件数据 "notes.txt"\nline 1\nline 2',
          },
        ]);
      },
    );

    for (final provider in _messageProviders) {
      test('${provider.name} encodes mixed files and attachment-only input', () async {
        final openAi = provider == ModelProvider.openAi;
        final client = _Client([
          _Response.sse(
            openAi
                ? '${_chat({}, finish: 'stop')}$_done'
                : '$_messageStart${_anthropicFinish('end_turn')}${_event('message_stop')}',
          ),
        ]);
        final model = _model(provider, client);
        addTearDown(model.close);

        await model.complete(
          messages: [
            _user,
            const AgentMessage.assistant('Please attach the files.'),
            const AgentMessage.user(
              'Read these files.',
              attachments: [_png, _pdf, notes],
            ),
            const AgentMessage.assistant('Any other files?'),
            const AgentMessage.user('', attachments: [jpeg, webp]),
            const AgentMessage.assistant('Any text files?'),
            AgentMessage.user(
              '',
              attachments: [
                for (final file in textFiles)
                  AgentAttachment(
                    name: file.name,
                    mimeType: file.mimeType,
                    base64Data: base64Encode(utf8.encode(file.text)),
                    text: file.text,
                  ),
              ],
            ),
          ],
          tools: [],
          onText: (_) {},
        );

        Json image(AgentAttachment attachment) => openAi
            ? {
                'type': 'image_url',
                'image_url': {
                  'url':
                      'data:${attachment.mimeType};base64,${attachment.base64Data}',
                },
              }
            : {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': attachment.mimeType,
                  'data': attachment.base64Data,
                },
              };

        final messages = (client.requests.single.json['messages'] as List)
            .cast<Json>();
        final users = messages.where((message) => message['role'] == 'user');
        expect(users.map((message) => message['content']), [
          _user.text,
          [
            {'type': 'text', 'text': 'Read these files.'},
            image(_png),
            if (openAi)
              {
                'type': 'file',
                'file': {
                  'filename': _pdf.name,
                  'file_data': 'data:application/pdf;base64,${_pdf.base64Data}',
                },
              }
            else
              {
                'type': 'document',
                'title': _pdf.name,
                'source': {
                  'type': 'base64',
                  'media_type': 'application/pdf',
                  'data': _pdf.base64Data,
                },
              },
            {'type': 'text', 'text': '文件数据 "notes.txt"\nline 1\nline 2'},
          ],
          [image(jpeg), image(webp)],
          if (openAi)
            textFiles
                .map((file) => '文件数据 "${file.name}"\n${file.text}')
                .join('\n\n')
          else
            [
              for (final file in textFiles)
                {'type': 'text', 'text': '文件数据 "${file.name}"\n${file.text}'},
            ],
        ]);
      });
    }

    test('rejects invalid attachments before opening a connection', () async {
      final client = _Client([]);
      final model = _model(ModelProvider.anthropic, client);
      addTearDown(model.close);

      for (final attachment in const [
        AgentAttachment(name: _key, mimeType: 'image/gif', base64Data: 'R0lG'),
        AgentAttachment(name: _key, mimeType: 'image/png', base64Data: _key),
        AgentAttachment(name: _key, mimeType: 'image/png', base64Data: ''),
        AgentAttachment(
          name: _key,
          mimeType: 'image/png',
          base64Data: 'iVBORw0KGgo',
        ),
        AgentAttachment(
          name: _key,
          mimeType: 'image/png',
          base64Data: _pdfHeader,
        ),
        AgentAttachment(name: _key, mimeType: 'text/plain', base64Data: 'YQ=='),
      ]) {
        await expectLater(
          model.complete(
            messages: [
              AgentMessage.user('', attachments: [attachment]),
            ],
            tools: [],
            onText: (_) {},
          ),
          _failsWith('附件格式'),
        );
      }
      expect(client.urls, isEmpty);
    });

    test('sends a campus PDF larger than the local attachment limit', () async {
      final client = _Client([
        _Response.sse('${_chat({}, finish: 'stop')}$_done'),
      ]);
      final model = _model(ModelProvider.openAi, client);
      addTearDown(model.close);
      final data = Uint8List(5 * 1024 * 1024 ~/ 2)
        ..setAll(0, ascii.encode('%PDF-'));
      final file = AgentAttachment.fromHost(
        name: '课程讲义.pdf',
        mimeType: 'application/pdf',
        data: base64Encode(data),
        isCampusFile: true,
      );
      await model.complete(
        messages: [
          AgentMessage.user('', attachments: [file]),
        ],
        tools: [],
        onText: (_) {},
      );
      expect(
        client.requests.single.contentLength,
        greaterThan(3 * 1024 * 1024),
      );
      expect(client.requests.single.contentLength, lessThan(12 * 1024 * 1024));
    });

    test(
      'caps raw files, UTF-8 text and the complete attachment request',
      () async {
        final client = _Client([
          _Response.sse('${_chat({}, finish: 'stop')}$_done'),
        ]);
        final model = _model(ModelProvider.openAi, client);
        addTearDown(model.close);

        AgentAttachment pdfOfSize(int size) => AgentAttachment(
          name: _pdf.name,
          mimeType: _pdf.mimeType,
          base64Data: base64Encode(
            Uint8List(size)..setAll(0, base64Decode(_pdf.base64Data)),
          ),
        );

        Future<AgentMessage> send(List<AgentMessage> messages) =>
            model.complete(messages: messages, tools: [], onText: (_) {});

        final maxPdf = pdfOfSize(agentMaxAttachmentBytes);
        final maxUser = AgentMessage.user('', attachments: [maxPdf]);
        await send([maxUser]);
        expect(client.requests.single.contentLength, greaterThan(128 * 1024));
        expect(client.requests.single.contentLength, lessThan(3 * 1024 * 1024));

        await expectLater(
          send([
            AgentMessage.user(
              '',
              attachments: [pdfOfSize(agentMaxAttachmentBytes + 1)],
            ),
          ]),
          _failsWith('附件超过大小上限'),
        );
        await expectLater(
          send([
            AgentMessage.user(
              '',
              attachments: [
                AgentAttachment(
                  name: notes.name,
                  mimeType: notes.mimeType,
                  base64Data: '',
                  text: '课' * (agentMaxTextAttachmentBytes ~/ 3 + 1),
                ),
              ],
            ),
          ]),
          _failsWith('附件超过大小上限'),
        );
        await expectLater(
          send([maxUser, const AgentMessage.assistant('Got it.'), maxUser]),
          _failsWith('模型请求超过大小上限'),
        );
        await expectLater(
          send([
            AgentMessage.user('a' * (512 * 1024), attachments: [maxPdf]),
          ]),
          _failsWith('模型请求超过大小上限'),
        );
        expect(client.urls, hasLength(1));
      },
    );
  });

  group('official DeepSeek PDFs', () {
    const document = AgentMessage.user('Read the PDF.', attachments: [_pdf]);
    const fileId = 'file-api-pdf-test';
    final filesUri = Uri.parse('https://api.deepseek.com/files');

    for (final provider in _messageProviders) {
      test('${provider.name} uploads and reuses a PDF across tool calls', () async {
        final openAi = provider == ModelProvider.openAi;
        final client = _Client([
          _Response.json(jsonEncode({'id': fileId})),
          _Response.sse(
            openAi
                ? '${_chat({
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_course',
                        'type': 'function',
                        'function': {'name': _tool.name, 'arguments': '{}'},
                      },
                    ],
                  }, finish: 'tool_calls')}$_done'
                : '$_messageStart'
                      '${_blockStart(0, {'type': 'tool_use', 'id': 'call_course', 'name': _tool.name, 'input': <String, Object>{}})}'
                      '${_blockStop(0)}${_anthropicFinish('tool_use')}${_event('message_stop')}',
          ),
          _deepSeekAnswer(provider),
        ]);
        final model = _model(
          provider,
          client,
          base: openAi
              ? 'https://api.deepseek.com:443/v1/'
              : 'https://api.deepseek.com/anthropic',
          name: 'deepseek-flash',
        );
        addTearDown(model.close);

        final reply = await model.complete(
          messages: [document],
          tools: [_tool],
          onText: (_) {},
        );
        expect(reply.calls.single.id, 'call_course');
        final finalReply = await model.complete(
          messages: [
            document,
            reply,
            const AgentMessage.tool('call_course', '[]'),
          ],
          tools: [_tool],
          onText: (_) {},
        );
        expect(finalReply.text, 'PDF read.');

        final chatUri = filesUri.replace(
          path: openAi ? '/chat/completions' : '/anthropic/v1/messages',
        );
        expect(client.urls, [filesUri, chatUri, chatUri]);
        final upload = client.requests.first;
        expect(upload.headers.value('authorization'), 'Bearer $_key');
        expect(upload.headers.value('x-api-key'), isNull);
        expect(upload.headers.value('accept'), 'application/json');
        final contentType = upload.headers.contentType!;
        expect(contentType.mimeType, 'multipart/form-data');
        final boundary = contentType.parameters['boundary'];
        expect(boundary, isNotNull);
        expect(upload.contentLength, upload.body.length);
        expect(
          latin1.decode(upload.body),
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="purpose"\r\n\r\n'
          'rich_layout_recognition\r\n'
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="expires_after[anchor]"\r\n\r\n'
          'created_at\r\n'
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="expires_after[seconds]"\r\n\r\n'
          '3600\r\n'
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="file"; filename="syllabus.pdf"\r\n'
          'Content-Type: application/pdf\r\n\r\n'
          '%PDF-1.4\n'
          '\r\n--$boundary--\r\n',
        );
        for (final request in client.requests) {
          expect(request.followRedirects, isFalse);
        }
        for (final request in client.requests.skip(1)) {
          expect(
            request.headers.value('authorization'),
            openAi ? 'Bearer $_key' : null,
          );
          expect(request.headers.value('x-api-key'), openAi ? null : _key);
          expect(
            request.headers.value('anthropic-beta'),
            openAi ? null : 'files-api-2025-04-14',
          );
          expect(request.json, containsPair('max_tokens', 4096));
          expect(request.json, isNot(contains('max_completion_tokens')));
          expect(request.json, containsPair('thinking', {'type': 'disabled'}));
          final messages = (request.json['messages'] as List).cast<Json>();
          expect(
            messages.firstWhere(
              (message) => message['role'] == 'user',
            )['content'],
            [
              {'type': 'text', 'text': document.text},
              if (openAi)
                {'type': 'file', 'file_id': fileId}
              else
                {
                  'type': 'document',
                  'source': {'type': 'file', 'file_id': fileId},
                },
            ],
          );
        }
        final continuation = client.requests.last.json['messages'] as List;
        expect(continuation.skip(openAi ? 2 : 1), [
          if (openAi) ...[
            {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_course',
                  'type': 'function',
                  'function': {'name': _tool.name, 'arguments': '{}'},
                },
              ],
            },
            {'role': 'tool', 'tool_call_id': 'call_course', 'content': '[]'},
          ] else ...[
            {
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'call_course',
                  'name': _tool.name,
                  'input': <String, Object>{},
                },
              ],
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 'call_course',
                  'content': '[]',
                },
              ],
            },
          ],
        ]);
      });
    }

    test('shares an in-flight upload for the same attachment', () async {
      final client = _Client([
        _Response.json(jsonEncode({'id': fileId})),
        _deepSeekAnswer(ModelProvider.openAi),
        _deepSeekAnswer(ModelProvider.openAi),
      ]);
      final model = _model(
        ModelProvider.openAi,
        client,
        base: 'https://api.deepseek.com',
        name: 'deepseek-flash',
      );
      addTearDown(model.close);
      Future<AgentMessage> send() =>
          model.complete(messages: [document], tools: [], onText: (_) {});

      final replies = await Future.wait([send(), send()]);
      expect(replies.map((reply) => reply.text), ['PDF read.', 'PDF read.']);
      expect(client.urls.where((url) => url == filesUri), [filesUri]);
    });

    test(
      'uses the validated attachment list if it changes during upload',
      () async {
        final client = _Client([
          _Response.json(jsonEncode({'id': fileId})),
          _deepSeekAnswer(ModelProvider.openAi),
        ]);
        final model = _model(
          ModelProvider.openAi,
          client,
          base: 'https://api.deepseek.com',
          name: 'deepseek-flash',
        );
        addTearDown(model.close);
        final attachments = [_pdf];
        final reply = model.complete(
          messages: [AgentMessage.user('', attachments: attachments)],
          tools: [],
          onText: (_) {},
        );
        await client.requestSent.future;
        attachments.add(
          const AgentAttachment(
            name: 'unvalidated.pdf',
            mimeType: 'application/pdf',
            base64Data: 'invalid',
          ),
        );
        expect((await reply).text, 'PDF read.');
        final messages = (client.requests.last.json['messages'] as List)
            .cast<Json>();
        expect(messages.last['content'], [
          {'type': 'file', 'file_id': fileId},
        ]);
      },
    );

    test('validates all attachments and JSON before uploading a PDF', () async {
      final client = _Client([]);
      final model = _model(
        ModelProvider.openAi,
        client,
        base: 'https://api.deepseek.com',
        name: 'deepseek-flash',
      );
      addTearDown(model.close);
      const invalid = AgentAttachment(
        name: _key,
        mimeType: 'application/pdf',
        base64Data: 'bm90IGEgcGRm',
      );
      final oversized = AgentAttachment(
        name: 'large.pdf',
        mimeType: 'application/pdf',
        base64Data: base64Encode(
          Uint8List(agentMaxAttachmentBytes + 1)
            ..setAll(0, base64Decode(_pdfHeader)),
        ),
      );
      for (final (attachment, error) in [
        (invalid, '附件格式'),
        (oversized, '附件超过大小上限'),
      ]) {
        await expectLater(
          model.complete(
            messages: [
              document,
              AgentMessage.user('', attachments: [attachment]),
            ],
            tools: [],
            onText: (_) {},
          ),
          _failsWith(error),
        );
      }
      await expectLater(
        model.complete(
          messages: [document, const AgentMessage.tool(null, _key)],
          tools: [],
          onText: (_) {},
        ),
        _failsWith('未关联到工具调用'),
      );
      expect(client.urls, isEmpty);
    });

    test(
      'rejects unsupported official API routes and models before upload',
      () async {
        for (final (base, name, error) in [
          ('https://api.deepseek.com/custom', 'deepseek-flash', '检查 API 地址'),
          (
            'https://api.deepseek.com',
            'deepseek-v4-pro',
            '需要使用 deepseek-flash',
          ),
        ]) {
          final client = _Client([]);
          final model = _model(
            ModelProvider.openAi,
            client,
            base: base,
            name: name,
          );
          addTearDown(model.close);
          await expectLater(
            model.complete(messages: [document], tools: [], onText: (_) {}),
            _failsWith(error),
          );
          expect(client.urls, isEmpty);
        }
      },
    );

    test(
      'keeps inline PDFs on lookalike hosts and nonstandard ports',
      () async {
        for (final base in [
          'https://api.deepseek.com.example.invalid',
          'https://api.deepseek.com:8443',
        ]) {
          final client = _Client([_deepSeekAnswer(ModelProvider.openAi)]);
          final model = _model(
            ModelProvider.openAi,
            client,
            base: base,
            name: 'deepseek-flash',
          );
          addTearDown(model.close);
          await model.complete(messages: [document], tools: [], onText: (_) {});
          expect(client.urls, [Uri.parse('$base/chat/completions')]);
          final wire = utf8.decode(client.requests.single.body);
          expect(wire, contains('data:application/pdf;base64,$_pdfHeader'));
          expect(wire, contains('max_completion_tokens'));
        }
      },
    );

    test(
      'sanitizes upload failures, disables redirects, and permits a retry',
      () async {
        final client = _Client([
          _Response.json(
            _key,
            status: 307,
            location: 'https://elsewhere.invalid',
          ),
          _Response.json(_key, status: 401),
          _Response.json(jsonEncode({'id': _key})),
          _Response.json(jsonEncode({'id': fileId, 'expires_at': 1})),
          _Response.json('x' * (16 * 1024 + 1)),
          _Response.json(jsonEncode({'id': fileId})),
          _deepSeekAnswer(ModelProvider.openAi),
        ]);
        final model = _model(
          ModelProvider.openAi,
          client,
          base: 'https://api.deepseek.com',
          name: 'deepseek-flash',
        );
        addTearDown(model.close);
        Future<AgentMessage> send() =>
            model.complete(messages: [document], tools: [], onText: (_) {});
        for (final error in ['重定向', '认证失败', ...List.filled(3, '文件信息无效')]) {
          await expectLater(send(), _failsWith(error));
          expect(client.urls.last, filesUri);
          expect(client.requests.last.followRedirects, isFalse);
        }
        expect((await send()).text, 'PDF read.');
        expect(client.urls, [
          ...List.filled(6, filesUri),
          filesUri.replace(path: '/chat/completions'),
        ]);
      },
    );
  });

  group('reasoning effort', () {
    for (final effort in AgentReasoningEffort.values.skip(1)) {
      test('OpenAI sends ${effort.name} with a larger output budget', () async {
        final client = _Client([
          _Response.sse('${_chat({'content': 'Done.'}, finish: 'stop')}$_done'),
        ]);
        final model = _model(
          ModelProvider.openAi,
          client,
          base: 'https://api.openai.com/v1',
          name: 'gpt-5.5',
          effort: effort,
        );
        addTearDown(model.close);
        final reply = await _complete(model);
        expect(reply.outputTruncated, isFalse);
        expect(
          client.requests.single.json,
          containsPair('reasoning_effort', effort.name),
        );
        expect(
          client.requests.single.json,
          containsPair('max_completion_tokens', 32768),
        );
      });
    }

    test('OpenAI omits effort for an official non-reasoning model', () async {
      final client = _Client([_deepSeekAnswer(ModelProvider.openAi)]);
      final model = _model(
        ModelProvider.openAi,
        client,
        base: 'https://api.openai.com/v1',
        name: 'gpt-4.1',
        effort: AgentReasoningEffort.high,
      );
      addTearDown(model.close);
      await _complete(model);
      expect(client.requests.single.json, isNot(contains('reasoning_effort')));
      expect(
        client.requests.single.json,
        containsPair('max_completion_tokens', 4096),
      );
    });

    for (final (name, thinking, outputConfig) in [
      ('claude-sonnet-4-6', {'type': 'adaptive'}, {'effort': 'medium'}),
      (
        'claude-opus-4-5-20251101',
        {'type': 'enabled', 'budget_tokens': 4096},
        {'effort': 'medium'},
      ),
      (
        'claude-haiku-4-5-20251001',
        {'type': 'enabled', 'budget_tokens': 4096},
        null,
      ),
      ('claude-3-haiku-20240307', null, null),
    ]) {
      test('Anthropic selects supported fields for $name', () async {
        final client = _Client([_deepSeekAnswer(ModelProvider.anthropic)]);
        final model = _model(
          ModelProvider.anthropic,
          client,
          base: 'https://api.anthropic.com/v1',
          name: name,
          effort: AgentReasoningEffort.medium,
        );
        addTearDown(model.close);
        await _complete(model);
        final body = client.requests.single.json;
        expect(body['thinking'], thinking);
        expect(body['output_config'], outputConfig);
        expect(body['max_tokens'], thinking == null ? 4096 : 32768);
        expect(body, isNot(contains('reasoning_effort')));
      });
    }

    for (final provider in _messageProviders) {
      for (final (effort, level) in [
        (AgentReasoningEffort.low, 'low'),
        (AgentReasoningEffort.medium, 'high'),
        (AgentReasoningEffort.high, 'max'),
      ]) {
        test(
          'DeepSeek ${provider.name} maps ${effort.name} to $level',
          () async {
            final client = _Client([_deepSeekAnswer(provider)]);
            final model = _model(
              provider,
              client,
              base: provider == ModelProvider.openAi
                  ? 'https://api.deepseek.com/v1'
                  : 'https://api.deepseek.com/anthropic',
              name: 'deepseek-flash',
              effort: effort,
            );
            addTearDown(model.close);
            await _complete(model);
            final body = client.requests.single.json;
            expect(body, containsPair('thinking', {'type': 'enabled'}));
            expect(body, containsPair('max_tokens', 32768));
            expect(body, isNot(contains('max_completion_tokens')));
            if (provider == ModelProvider.openAi) {
              expect(body, containsPair('reasoning_effort', level));
            } else {
              expect(body, containsPair('output_config', {'effort': level}));
            }
          },
        );
      }
    }

    test('DeepSeek folds saved answers and replays reasoning only for current tools', () async {
      String toolRound(String id) =>
          '${_chat({'reasoning_content': 'hidden $id '})}'
          '${_chat({'reasoning_content': 'tail'})}'
          '${_chat({
            'tool_calls': [
              {
                'index': 0,
                'id': id,
                'type': 'function',
                'function': {'name': 'courses', 'arguments': '{}'},
              },
            ],
          }, finish: 'tool_calls')}$_done';
      final client = _Client([
        _Response.sse(toolRound('first')),
        _Response.sse(toolRound('second')),
        _Response.sse(
          '${_chat({'reasoning_content': 'hidden final'})}'
          '${_chat({'content': 'Done.'}, finish: 'stop')}$_done',
        ),
        _deepSeekAnswer(ModelProvider.openAi),
      ]);
      final model = _model(
        ModelProvider.openAi,
        client,
        base: 'https://api.deepseek.com',
        name: 'deepseek-flash',
        effort: AgentReasoningEffort.medium,
      );
      addTearDown(model.close);
      final messages = <AgentMessage>[
        const AgentMessage.user('Earlier question.'),
        const AgentMessage.assistant('Saved answer.'),
        _user,
      ];
      final deltas = <String>[];
      Future<AgentMessage> run() => model.complete(
        messages: messages,
        tools: [_tool],
        onText: deltas.add,
      );

      final first = await run();
      expect(first.text, isEmpty);
      expect(first.calls.single.id, 'first');
      messages.addAll([
        first,
        const AgentMessage.tool('first', '[]'),
        _attachedUser,
      ]);
      final second = await run();
      expect(second.text, isEmpty);
      expect(second.calls.single.id, 'second');
      messages.addAll([second, const AgentMessage.tool('second', '[]')]);
      final reply = await run();
      expect(reply.text, 'Done.');
      expect(deltas, ['Done.']);

      List<Json> sent(int index) =>
          (client.requests[index].json['messages'] as List).cast<Json>();
      Iterable<Object?> replayed(int index) =>
          sent(index)
              .where((message) => message.containsKey('reasoning_content'))
              .map((message) => message['reasoning_content']);
      expect(sent(0).map((message) => message['role']), ['system', 'user']);
      final context = sent(0).last['content'];
      expect(context, contains('Earlier question.'));
      expect(context, contains('Saved answer.'));
      expect(context, endsWith(_user.text));
      expect(replayed(0), isEmpty);
      expect(replayed(1), ['hidden first tail']);
      expect(replayed(2), ['hidden first tail', 'hidden second tail']);
      expect(sent(2).map((message) => message['role']), [
        'system',
        'user',
        'assistant',
        'tool',
        'user',
        'assistant',
        'tool',
      ]);
      expect(sent(2)[1]['content'], context);

      messages.addAll([
        reply,
        const AgentMessage.user('Next question.', attachments: [_png]),
      ]);
      await run();
      expect(replayed(3), isEmpty);
      expect(sent(3).map((message) => message['role']), ['system', 'user']);
      final nextContent = (sent(3).last['content'] as List).cast<Json>();
      expect(nextContent.first['text'], contains('Saved answer.'));
      expect(nextContent.first['text'], contains('Done.'));
      expect(nextContent.first['text'], endsWith('Next question.'));
      expect(nextContent.first['text'], isNot(contains('hidden')));
      expect(nextContent.last['type'], 'image_url');
    });
  });

  group('terminal events and sanitized failures', () {
    test(
      'OpenAI length preserves streamed text and discards unfinished calls',
      () async {
        final client = _Client([
          _Response.sse(
            '${_chat({'content': 'Partial answer.'})}'
            '${_chat({
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': '{'},
                },
              ],
            }, finish: 'length')}$_done',
          ),
        ]);
        final model = _model(ModelProvider.openAi, client);
        addTearDown(model.close);
        final deltas = <String>[];
        final reply = await model.complete(
          messages: [_user],
          tools: [_tool],
          onText: deltas.add,
        );
        expect(reply.outputTruncated, isTrue);
        expect(reply.text, 'Partial answer.');
        expect(reply.calls, isEmpty);
        expect(deltas, ['Partial answer.']);
      },
    );

    test('Anthropic max_tokens reports a reasoning-only response as truncated', () async {
      final client = _Client([
        _Response.sse(
          '$_messageStart'
          '${_blockStart(0, {'type': 'thinking', 'thinking': ''})}'
          '${_blockDelta(0, {'type': 'thinking_delta', 'thinking': 'Hidden.'})}'
          '${_blockStop(0)}${_anthropicFinish('max_tokens')}${_event('message_stop')}',
        ),
      ]);
      final model = _model(ModelProvider.anthropic, client);
      addTearDown(model.close);
      final deltas = <String>[];
      final reply = await model.complete(
        messages: [_user],
        tools: [],
        onText: deltas.add,
      );
      expect(reply.outputTruncated, isTrue);
      expect(reply.text, isEmpty);
      expect(reply.calls, isEmpty);
      expect(deltas, isEmpty);
    });

    final cases = <({String name, ModelProvider provider, String wire, String error})>[
      (
        name: 'OpenAI EOF after finish',
        provider: ModelProvider.openAi,
        wire: _chat({}, finish: 'stop'),
        error: '中断',
      ),
      (
        name: 'OpenAI DONE without finish',
        provider: ModelProvider.openAi,
        wire: _done,
        error: '中断',
      ),
      (
        name: 'OpenAI incomplete DONE frame',
        provider: ModelProvider.openAi,
        wire: '${_chat({}, finish: 'stop')}data: [DONE]\n',
        error: '中断',
      ),
      (
        name: 'OpenAI refusal delta',
        provider: ModelProvider.openAi,
        wire: '${_chat({'refusal': _key}, finish: 'stop')}$_done',
        error: '拒绝',
      ),
      (
        name: 'OpenAI malformed JSON',
        provider: ModelProvider.openAi,
        wire: 'data: {$_key\n\n',
        error: '格式无效',
      ),
      (
        name: 'Anthropic EOF after stop reason',
        provider: ModelProvider.anthropic,
        wire: '$_messageStart${_anthropicFinish('end_turn')}',
        error: '中断',
      ),
      (
        name: 'Anthropic message_stop without reason',
        provider: ModelProvider.anthropic,
        wire: '$_messageStart${_event('message_stop')}',
        error: '中断',
      ),
      (
        name: 'Anthropic mismatched stop event',
        provider: ModelProvider.anthropic,
        wire:
            '$_messageStart${_anthropicFinish('end_turn')}event: message_stop\ndata: {"type":"ping"}\n\n',
        error: '格式无效',
      ),
      (
        name: 'Anthropic tool block left open',
        provider: ModelProvider.anthropic,
        wire:
            '$_messageStart${_blockStart(0, {'type': 'tool_use', 'id': 'tool_a', 'name': 'courses', 'input': <String, dynamic>{}})}${_event('message_stop')}',
        error: '中断',
      ),
      (
        name: 'Anthropic context limit',
        provider: ModelProvider.anthropic,
        wire:
            '$_messageStart${_anthropicFinish('model_context_window_exceeded')}${_event('message_stop')}',
        error: '上下文上限',
      ),
      (
        name: 'Anthropic overload',
        provider: ModelProvider.anthropic,
        wire: _event('error', {
          'error': {'type': 'overloaded_error', 'message': _key},
        }),
        error: '繁忙',
      ),
    ];
    for (final scenario in cases) {
      test(scenario.name, () async {
        final model = _model(
          scenario.provider,
          _Client([_Response.sse(scenario.wire)]),
        );
        addTearDown(model.close);
        await expectLater(_complete(model), _failsWith(scenario.error));
      });
    }
  });

  test(
    'rejects redirects and HTTP failures without exposing response bodies',
    () async {
      final client = _Client([
        _Response.sse(
          _key,
          status: 307,
          location: 'https://elsewhere.invalid/$_key',
        ),
        _Response.sse(_key, status: 401),
      ]);
      final model = _model(ModelProvider.openAi, client);
      addTearDown(model.close);
      await expectLater(_complete(model), _failsWith('HTTP 307'));
      expect(client.urls, hasLength(1));
      expect(client.requests.single.followRedirects, isFalse);
      await expectLater(_complete(model), _failsWith('HTTP 401'));
    },
  );

  test('rejects non-SSE success responses', () async {
    final client = _Client([
      _Response(
        Stream.value(utf8.encode(_key)),
        contentType: 'application/json',
      ),
    ]);
    final model = _model(ModelProvider.openAi, client);
    addTearDown(model.close);
    await expectLater(_complete(model), _failsWith('SSE'));
  });

  test('validates HTTPS before dialing and caps request bytes', () async {
    final client = _Client([]);
    for (final url in [
      'http://provider.invalid/v1',
      'https://$_key@provider.invalid/v1',
      'https://provider.invalid/v1?key=$_key',
      'https://provider.invalid/v1#$_key',
    ]) {
      final model = _model(ModelProvider.openAi, client, base: url);
      addTearDown(model.close);
      await expectLater(_complete(model), _failsWith('HTTPS'));
    }
    final model = _model(ModelProvider.openAi, client);
    addTearDown(model.close);
    await expectLater(
      model.complete(
        messages: [AgentMessage.user('课' * 50000)],
        tools: [],
        onText: (_) {},
      ),
      _failsWith('大小上限'),
    );
    expect(client.urls, isEmpty);
  });

  test('bounds the stream even when an SSE line has no newline', () async {
    final client = _Client([
      _Response(Stream.value(Uint8List(2 * 1024 * 1024 + 1))),
    ]);
    final model = _model(ModelProvider.openAi, client);
    addTearDown(model.close);
    await expectLater(_complete(model), _failsWith('大小上限'));
  });

  test(
    'close cancels while awaiting response headers and blocks future requests',
    () async {
      final waiting = Completer<HttpClientResponse>();
      final client = _Client([], onResponse: () => waiting.future);
      final model = _model(ModelProvider.openAi, client);
      final result = expectLater(_complete(model), _failsWith('取消'));
      await client.requestSent.future;
      model.close();
      model.close();
      await result;
      expect(client.forceClosed, isTrue);
      await expectLater(_complete(model), _failsWith('取消'));
      expect(client.urls, hasLength(1));
      waiting.completeError(const SocketException(_key));
    },
  );

  test(
    'close stops streaming callbacks and cancels the response listener',
    () async {
      final cancelled = Completer<void>();
      final controller = StreamController<List<int>>(
        onCancel: cancelled.complete,
      );
      final client = _Client(
        [_Response(controller.stream)],
        onClose: () {
          controller.addError(const SocketException(_key));
          unawaited(controller.close());
        },
      );
      final model = _model(ModelProvider.openAi, client);
      final first = Completer<void>();
      final deltas = <String>[];
      final result = expectLater(
        model.complete(
          messages: [_user],
          tools: [],
          onText: (delta) {
            deltas.add(delta);
            if (!first.isCompleted) first.complete();
          },
        ),
        _failsWith('取消'),
      );
      controller.add(utf8.encode(_chat({'content': 'first'})));
      await first.future;
      controller.add(utf8.encode(_chat({'content': 'second'})));
      model.close();
      await result;
      await cancelled.future;
      expect(deltas, ['first']);
    },
  );
}

StreamingAgentModel _model(
  ModelProvider provider,
  _Client client, {
  String? base,
  String name = 'test-model',
  AgentReasoningEffort effort = AgentReasoningEffort.defaultEffort,
}) => StreamingAgentModel(
  AgentModelConfig(
    provider: provider,
    baseUrl: Uri.parse(base ?? 'https://provider.invalid/prefix/v1/'),
    model: name,
    apiKey: _key,
    reasoningEffort: effort,
  ),
  client: client,
);

Future<AgentMessage> _complete(StreamingAgentModel model) =>
    model.complete(messages: [_user], tools: [], onText: (_) {});

Matcher _failsWith(String message) => throwsA(
  isA<AgentFailure>().having(
    (error) => error.message,
    'message',
    allOf(contains(message), isNot(contains(_key))),
  ),
);

String _chat(Json delta, {String? finish}) =>
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    })}\n\n';

String _event(String type, [Json fields = const {}]) =>
    'event: $type\ndata: ${jsonEncode({'type': type, ...fields})}\n\n';

Json _responsesMessage(String text) => {
  'type': 'message',
  'role': 'assistant',
  'status': 'completed',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
};

Json _responsesCall(String id, String arguments) => {
  'type': 'function_call',
  'id': 'item-$id',
  'call_id': id,
  'status': 'completed',
  'name': _tool.name,
  'arguments': arguments,
};

String _responsesDelta(String delta, {int output = 0}) => _event(
  'response.output_text.delta',
  {'output_index': output, 'content_index': 0, 'delta': delta},
);

String _responsesItemDone(int output, Json item) =>
    _event('response.output_item.done', {'output_index': output, 'item': item});

String _responsesTerminal(
  List<Json> output, {
  String status = 'completed',
  String? reason,
  Json? error,
}) => _event('response.$status', {
  'response': {
    'status': status,
    'output': output,
    if (reason != null) 'incomplete_details': {'reason': reason},
    'error': ?error,
  },
});

String get _messageStart => _event('message_start', {
  'message': {'content': <Object>[], 'stop_reason': null},
});

String _blockStart(int index, Json block) =>
    _event('content_block_start', {'index': index, 'content_block': block});
String _blockDelta(int index, Json delta) =>
    _event('content_block_delta', {'index': index, 'delta': delta});
String _blockStop(int index) => _event('content_block_stop', {'index': index});
String _anthropicFinish(String reason) => _event('message_delta', {
  'delta': {'stop_reason': reason},
});

_Response _deepSeekAnswer(ModelProvider provider) => _Response.sse(
  provider == ModelProvider.openAi
      ? '${_chat({'content': 'PDF read.'})}'
            '${_chat({}, finish: 'stop')}$_done'
      : '$_messageStart'
            '${_blockStart(0, {'type': 'text', 'text': 'PDF read.'})}'
            '${_blockStop(0)}${_anthropicFinish('end_turn')}${_event('message_stop')}',
);

class _Client implements HttpClient {
  _Client(this.responses, {this.onResponse, this.onClose});

  final List<_Response> responses;
  final Future<HttpClientResponse> Function()? onResponse;
  final void Function()? onClose;
  final urls = <Uri>[];
  final requests = <_Request>[];
  final requestSent = Completer<void>();
  bool forceClosed = false;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    urls.add(url);
    final request = _Request(() async {
      if (!requestSent.isCompleted) requestSent.complete();
      return onResponse == null ? responses.removeAt(0) : await onResponse!();
    });
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    forceClosed = force;
    onClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this._response);

  final Future<HttpClientResponse> Function() _response;
  final _body = BytesBuilder();

  @override
  final headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  int contentLength = -1;

  Uint8List get body => _body.toBytes();

  Json get json => jsonDecode(utf8.decode(body)) as Json;

  @override
  void add(List<int> data) => _body.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}

  @override
  Future<HttpClientResponse> close() => _response();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this._body, {
    this.statusCode = 200,
    String? location,
    String contentType = 'text/event-stream; charset=utf-8',
  }) {
    headers.set('content-type', contentType);
    if (location != null) headers.set('location', location);
  }

  factory _Response.sse(String wire, {int status = 200, String? location}) =>
      _Response(
        Stream.fromIterable(utf8.encode(wire).map((byte) => [byte])),
        statusCode: status,
        location: location,
      );

  factory _Response.json(String wire, {int status = 200, String? location}) =>
      _Response(
        Stream.value(utf8.encode(wire)),
        statusCode: status,
        location: location,
        contentType: 'application/json',
      );

  final Stream<List<int>> _body;

  @override
  final int statusCode;

  @override
  final headers = _Headers();

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
  final _values = <String, String>{};

  @override
  ContentType? get contentType {
    final header = value('content-type');
    return header == null ? null : ContentType.parse(header);
  }

  @override
  set contentType(ContentType? type) {
    if (type != null) set('content-type', type.toString());
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = value.toString();

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
