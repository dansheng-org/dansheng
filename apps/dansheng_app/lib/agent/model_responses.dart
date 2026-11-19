// SPDX-License-Identifier: GPL-3.0-or-later

part of 'model_providers.dart';

({Json fields, bool isEnabled}) _responsesReasoning(
  AgentModelConfig config, {
  required bool deepSeek,
}) {
  final effort = config.reasoningEffort;
  final explicit = effort != AgentReasoningEffort.defaultEffort;
  if (deepSeek) {
    final level = switch (effort) {
      AgentReasoningEffort.defaultEffort => null,
      AgentReasoningEffort.low => 'low',
      AgentReasoningEffort.medium => 'high',
      AgentReasoningEffort.high => 'max',
    };
    // DeepSeek Responses enables thinking by default.
    return (
      fields: {
        if (level != null) 'reasoning': {'effort': level},
      },
      isEnabled: true,
    );
  }

  final model = config.model.toLowerCase();
  final supportsEffort =
      _openAiReasoningModel.hasMatch(model) && !model.endsWith('-chat-latest');
  final officialOpenAi = config.baseUrl.host == 'api.openai.com';
  final sendEffort = explicit && (supportsEffort || !officialOpenAi);
  return (
    fields: {
      'store': false,
      if (sendEffort) 'reasoning': {'effort': effort.name},
      if (officialOpenAi && supportsEffort)
        'include': ['reasoning.encrypted_content'],
    },
    isEnabled: supportsEffort || sendEffort,
  );
}

List<AgentMessage> _responsesRequestMessages(
  List<AgentMessage> messages, {
  required bool allowRetry,
  required bool foldHistory,
}) {
  var index = messages.length - 1;
  // The runner can append a user-role retry after an incomplete or empty
  // answer. Keep the current question, attachments and tool results for it.
  if (allowRetry && index > 0 && _isTurnStart(messages, index)) {
    final previous = messages[index - 1];
    if (previous.role != AgentRole.assistant || previous.outputTruncated) {
      index--;
    }
  }
  final start = _currentTurnStart(messages, index);
  if (foldHistory) return _deepSeekCurrentTurn(messages, turnStart: start);
  if (start <= 0) return messages;
  return [
    for (var index = 0; index < start; index++)
      if (messages[index].text.trim().isNotEmpty)
        if (_isTurnStart(messages, index))
          AgentMessage.user(messages[index].text)
        else if (messages[index].role == AgentRole.assistant)
          AgentMessage.assistant(messages[index].text),
    ...messages.skip(start),
  ];
}

Json _responsesPayload(
  AgentModelConfig config,
  List<AgentMessage> messages,
  List<AgentToolSpec> tools,
  Map<AgentMessage, List<Json>> replay,
  Map<AgentAttachment, Json> fileSources, {
  required bool deepSeek,
  required Json reasoningFields,
  required int outputTokens,
}) => {
  'model': config.model,
  'stream': true,
  'instructions': agentSystemPrompt,
  'max_output_tokens': outputTokens,
  ...reasoningFields,
  'input': _responsesInput(messages, replay, fileSources),
  if (tools.isNotEmpty)
    'tools': [
      for (final tool in tools)
        {
          'type': 'function',
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.inputSchema,
          if (!deepSeek) 'strict': false,
        },
    ],
};

List<Json> _responsesInput(
  List<AgentMessage> messages,
  Map<AgentMessage, List<Json>> replay,
  Map<AgentAttachment, Json> fileSources,
) {
  final items = <Json>[];
  final calls = <String>{};
  final pending = <String>{};
  var remainingArgumentBytes = _maxRequestBytes;
  for (final message in messages) {
    switch (message.role) {
      case AgentRole.user:
        items.add({
          'type': 'message',
          'role': 'user',
          'content': _userContentBlocks(
            message,
            ModelProvider.openAiResponses,
            fileSources,
          ),
        });
      case AgentRole.assistant:
        for (final call in message.calls) {
          if (call.id.isEmpty || !calls.add(call.id)) {
            throw _unpairedResponsesCall;
          }
          pending.add(call.id);
        }
        if (replay[message] case final output?) {
          items.addAll(output);
          continue;
        }
        if (message.text.isNotEmpty) {
          items.add({
            'type': 'message',
            'role': 'assistant',
            'content': message.text,
          });
        }
        for (final call in message.calls) {
          final arguments = _encodeJson(
            call.arguments ?? const <String, dynamic>{},
            remainingArgumentBytes,
          );
          remainingArgumentBytes -= arguments.length;
          items.add({
            'type': 'function_call',
            'call_id': call.id,
            'name': call.name,
            'arguments': utf8.decode(arguments),
          });
        }
      case AgentRole.tool:
        final id = _resultId(message);
        if (!pending.remove(id)) throw _unpairedResponsesCall;
        items.add({
          'type': 'function_call_output',
          'call_id': id,
          'output': message.text,
        });
    }
  }
  if (pending.isNotEmpty) throw _unpairedResponsesCall;
  return items;
}

const _unpairedResponsesCall = _ProviderFailure('模型对话包含未配对的工具调用或结果。');

Future<AgentMessage> _readResponses(
  Stream<_SseEvent> events,
  _AssistantTurn turn,
  Expando<List<Json>> replay,
) async {
  final text = _ResponsesText(turn);
  await for (final event in events) {
    if (event.data == '[DONE]') throw _truncatedStream;
    final payload = _object(jsonDecode(event.data));
    if (event.name == 'error' ||
        payload['type'] == 'error' ||
        payload['error'] != null) {
      throw _streamFailure(
        payload['error'] != null ? payload : {'error': payload},
      );
    }
    final type = _requiredString(payload['type']);
    if (event.name != null && event.name != type) throw _invalidStream;
    switch (type) {
      case 'response.output_text.delta':
        text.addDelta(payload);
      case 'response.output_text.done':
        text.finishPart(payload);
      case 'response.output_item.done':
        text.finishItem(payload);
      case 'response.refusal.delta' || 'response.refusal.done':
        throw _refusal;
      case 'response.completed' || 'response.incomplete' || 'response.failed':
        final response = _object(payload['response']);
        if (type == 'response.failed' || response['error'] != null) {
          throw _streamFailure(response);
        }
        final incomplete = type == 'response.incomplete';
        if (response['status'] != (incomplete ? 'incomplete' : 'completed')) {
          throw _invalidStream;
        }
        if (incomplete) {
          switch (_object(response['incomplete_details'])['reason']) {
            case 'max_output_tokens':
              break;
            case 'content_filter':
              throw _refusal;
            default:
              throw _unsupportedStop;
          }
        }
        return _finishResponses(response, turn, replay, incomplete: incomplete);
    }
  }
  throw _truncatedStream;
}

AgentMessage _finishResponses(
  Json response,
  _AssistantTurn turn,
  Expando<List<Json>> replay, {
  required bool incomplete,
}) {
  final output = _array(response['output']);
  if (output.length > _maxBlocks) throw _invalidStream;
  final visible = StringBuffer();
  final replayItems = <Json>[];
  for (var index = 0; index < output.length; index++) {
    final item = _object(output[index]);
    switch (_requiredString(item['type'])) {
      case 'message':
        visible.write(_responsesMessageText(item));
        replayItems.add(item);
      case 'function_call':
        if (incomplete) continue;
        if (item['status'] != null && item['status'] != 'completed') {
          throw _invalidStream;
        }
        final arguments = item['arguments'];
        if (arguments is! String) throw _invalidStream;
        turn.tools[index] = _ToolInput()
          ..id = _requiredString(item['call_id'])
          ..name = _requiredString(item['name'])
          ..fragments.write(arguments);
        replayItems.add(item);
      case 'reasoning':
        replayItems.add(item);
      case 'custom_tool_call' || 'tool_search_call':
        if (!incomplete) throw _unsupportedStop;
    }
  }

  _addResponsesTextSuffix(visible.toString(), turn.text, turn.addText);
  if (incomplete) return AgentMessage.assistantTruncated(turn.text.toString());
  final reply = turn.finish(expectsTools: turn.tools.isNotEmpty);
  if (reply.calls.isNotEmpty) replay[reply] = replayItems;
  return reply;
}

String _responsesMessageText(Json item) {
  if (item['type'] != 'message') return '';
  if (item['role'] != 'assistant') throw _invalidStream;
  final parts = _array(item['content']);
  if (parts.length > _maxBlocks) throw _invalidStream;
  final text = StringBuffer();
  for (final value in parts) {
    final part = _object(value);
    switch (_requiredString(part['type'])) {
      case 'output_text':
        final content = part['text'];
        if (content is! String) throw _invalidStream;
        text.write(content);
      case 'refusal':
        throw _refusal;
    }
  }
  return text.toString();
}

// Stream the ordered prefix immediately. The terminal output supplies any
// parts deferred by interleaving and the exact items for tool continuation.
class _ResponsesText {
  _ResponsesText(this.turn);

  final _AssistantTurn turn;
  var _outputIndex = 0;
  var _contentIndex = 0;
  var _deferred = false;
  var _item = StringBuffer();
  var _part = StringBuffer();

  bool _currentPart(Json event) {
    final output = _responsesIndex(event['output_index']);
    final content = _responsesIndex(event['content_index']);
    _deferred |= output != _outputIndex || content != _contentIndex;
    return !_deferred;
  }

  void addDelta(Json event) {
    final delta = event['delta'];
    if (delta is! String) throw _invalidStream;
    if (_currentPart(event)) _add(delta);
  }

  void finishPart(Json event) {
    final text = event['text'];
    if (text is! String) throw _invalidStream;
    if (!_currentPart(event)) return;
    _addResponsesTextSuffix(text, _part, _add);
    _part = StringBuffer();
    _contentIndex++;
  }

  void finishItem(Json event) {
    final output = _responsesIndex(event['output_index']);
    _deferred |= output != _outputIndex;
    if (_deferred) return;
    final text = _responsesMessageText(_object(event['item']));
    _addResponsesTextSuffix(text, _item, turn.addText);
    _item = StringBuffer();
    _part = StringBuffer();
    _outputIndex++;
    _contentIndex = 0;
  }

  void _add(String value) {
    _item.write(value);
    _part.write(value);
    turn.addText(value);
  }
}

int _responsesIndex(Object? index) =>
    index is int && index >= 0 && index < _maxBlocks
    ? index
    : throw _invalidStream;

void _addResponsesTextSuffix(
  String full,
  StringBuffer streamed,
  void Function(String) add,
) {
  if (!full.startsWith(streamed.toString())) throw _invalidStream;
  if (full.length > streamed.length) add(full.substring(streamed.length));
}
