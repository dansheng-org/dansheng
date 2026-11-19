// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'agent_types.dart';

const _maxOutputTokens = 1024;
const _maxRequestBytes = 128 * 1024;
// Allow for base64 expansion of a 2 MiB attachment and the JSON envelope.
const _maxAttachmentRequestBytes = 3 * 1024 * 1024;
// Campus PDF fallbacks can carry up to 8 MiB before base64 encoding.
const _maxCampusPdfRequestBytes = 12 * 1024 * 1024;
const _textAttachmentMimeTypes = {
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json',
};
const _maxStreamBytes = 512 * 1024;
const _maxBlocks = 128;
const _ioTimeout = Duration(seconds: 60);
const _cancelled = AgentFailure('模型请求已取消。');
const _deepSeekFilesBeta = 'files-api-2025-04-14';
const _deepSeekFileLifetime = Duration(hours: 1);
// DeepSeek allows up to 120 seconds each for upload and parsing.
const _deepSeekUploadTimeout = Duration(seconds: 250);
const _deepSeekFileResponseLimit = 16 * 1024;
final _deepSeekFilesUri = Uri.https('api.deepseek.com', '/files');
final _deepSeekFileIdPattern = RegExp(r'^file-api-[a-zA-Z0-9_-]{1,128}$');
typedef _DeepSeekFile = ({String id, int expiresAt});

class StreamingAgentModel implements AgentModel {
  /// Takes ownership of [client] when one is supplied.
  StreamingAgentModel(this._config, {HttpClient? client})
    : _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final AgentModelConfig _config;
  final HttpClient _client;
  final _pending = <Completer<AgentMessage>>{};
  // The runner reuses the returned message on the same model for each tool round.
  final _anthropicBlocks = Expando<List<Json>>();
  final _deepSeekFiles = Expando<Future<_DeepSeekFile>>();
  bool _closed = false;

  @override
  Future<AgentMessage> complete({
    required List<AgentMessage> messages,
    required List<AgentToolSpec> tools,
    required void Function(String) onText,
  }) async {
    if (_closed) throw _cancelled;
    final cancellation = Completer<AgentMessage>();
    _pending.add(cancellation);
    try {
      return await Future.any([
        _complete(messages, tools, onText),
        cancellation.future,
      ]);
    } finally {
      _pending.remove(cancellation);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final cancellation in _pending) {
      cancellation.completeError(_cancelled);
    }
    _client.close(force: true);
  }

  Future<AgentMessage> _complete(
    List<AgentMessage> messages,
    List<AgentToolSpec> tools,
    void Function(String) onText,
  ) async {
    var readingStream = false;
    try {
      final provider = _config.provider;
      final configuredUri = _endpoint(_config);
      final officialDeepSeek = configuredUri.origin == _deepSeekFilesUri.origin;
      final deepSeekChat = officialDeepSeek
          ? _deepSeekChatEndpoint(configuredUri, provider)
          : null;
      final uri = deepSeekChat ?? configuredUri;
      _validateRequest(_config, messages, tools);
      final deepSeekPdfs = officialDeepSeek
          ? <AgentAttachment, Uint8List>{}
          : null;
      final requestLimit = _attachmentRequestLimit(messages, deepSeekPdfs);
      final fileSources = <AgentAttachment, Json>{};
      if (deepSeekPdfs != null && deepSeekPdfs.isNotEmpty) {
        if (deepSeekChat == null) {
          throw const _ProviderFailure(
            'DeepSeek PDF 需要使用官方聊天 API。请检查 API 地址和协议。',
          );
        }
        if (!_supportsDeepSeekPdf(_config)) {
          throw const _ProviderFailure('DeepSeek PDF 需要使用 deepseek-flash 模型。');
        }
        // Validate the complete JSON envelope before starting a billable upload.
        final longestId = 'file-api-${'0' * 128}';
        for (final attachment in deepSeekPdfs.keys) {
          fileSources[attachment] = {'type': 'file', 'file_id': longestId};
        }
      }
      final body = await _requestBody(
        _config,
        messages,
        tools,
        _anthropicBlocks,
        requestLimit,
        fileSources,
        deepSeek: deepSeekChat != null,
        uploadFiles: deepSeekPdfs == null || deepSeekPdfs.isEmpty
            ? null
            : () async {
                for (final entry in deepSeekPdfs.entries) {
                  final id = await _deepSeekFileId(entry.key, entry.value);
                  fileSources[entry.key]!['file_id'] = id;
                }
              },
      );

      if (_closed) throw _cancelled;
      final request = await _client.postUrl(uri);
      if (_closed) {
        request.abort();
        throw _cancelled;
      }
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      switch (provider) {
        case ModelProvider.openAi:
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${_config.apiKey}',
          );
        case ModelProvider.anthropic:
          request.headers.set('x-api-key', _config.apiKey);
          request.headers.set('anthropic-version', '2023-06-01');
          if (fileSources.isNotEmpty) {
            request.headers.set('anthropic-beta', _deepSeekFilesBeta);
          }
      }
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(
        _ioTimeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('Model response headers');
        },
      );
      if (_closed) {
        await response.listen(null).cancel();
        throw _cancelled;
      }
      final status = response.statusCode;
      if (status != HttpStatus.ok) {
        await response.listen(null).cancel();
        throw _httpFailure(status);
      }
      if (response.headers.contentType?.mimeType.toLowerCase() !=
          'text/event-stream') {
        await response.listen(null).cancel();
        throw const _ProviderFailure('模型服务未返回 SSE 流。');
      }

      final turn = _AssistantTurn((text) {
        if (_closed) throw _cancelled;
        try {
          onText(text);
        } catch (_) {
          throw const _ProviderFailure('无法传递模型生成的文本。');
        }
      });
      readingStream = true;
      final events = _sseEvents(response.timeout(_ioTimeout));
      final result = await switch (provider) {
        ModelProvider.openAi => _readOpenAi(events, turn),
        ModelProvider.anthropic => _readAnthropic(
          events,
          turn,
          _anthropicBlocks,
        ),
      };
      if (_closed) throw _cancelled;
      return result;
    } on _ProviderFailure catch (error) {
      throw _closed ? _cancelled : AgentFailure(error.message);
    } on TimeoutException {
      throw _closed ? _cancelled : const AgentFailure('等待模型服务响应超时。');
    } on TlsException {
      throw _closed ? _cancelled : const AgentFailure('无法建立模型服务的 TLS 连接。');
    } on FormatException {
      throw _closed ? _cancelled : const AgentFailure('模型服务返回的流格式无效。');
    } catch (_) {
      if (_closed) throw _cancelled;
      throw AgentFailure(readingStream ? '模型响应流连接中断。' : '无法连接模型服务。');
    }
  }

  Future<String> _deepSeekFileId(
    AgentAttachment attachment,
    Uint8List bytes,
  ) async {
    var pending = _deepSeekFiles[attachment];
    while (pending != null) {
      final file = await pending;
      if (_unixSeconds() < file.expiresAt) return file.id;
      if (identical(_deepSeekFiles[attachment], pending)) {
        _deepSeekFiles[attachment] = null;
      }
      pending = _deepSeekFiles[attachment];
    }

    if (_closed) throw _cancelled;
    final upload = _uploadDeepSeekPdf(bytes);
    _deepSeekFiles[attachment] = upload;
    try {
      return (await upload).id;
    } catch (_) {
      _deepSeekFiles[attachment] = null;
      rethrow;
    }
  }

  Future<_DeepSeekFile> _uploadDeepSeekPdf(Uint8List bytes) async {
    try {
      // Both message protocols accept IDs from /files, which documents expiry.
      final expiresAt = _unixSeconds() + _deepSeekFileLifetime.inSeconds;
      final random = Random.secure();
      final boundary = base64UrlEncode(
        List.generate(24, (_) => random.nextInt(256)),
      );
      final prefix = ascii.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="purpose"\r\n\r\n'
        'text_recognition\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="expires_after[anchor]"\r\n\r\n'
        'created_at\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="expires_after[seconds]"\r\n\r\n'
        '${_deepSeekFileLifetime.inSeconds}\r\n'
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; filename="document.pdf"\r\n'
        'Content-Type: application/pdf\r\n\r\n',
      );
      final suffix = ascii.encode('\r\n--$boundary--\r\n');
      final request = await _client.postUrl(_deepSeekFilesUri);
      if (_closed) {
        request.abort();
        throw _cancelled;
      }
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_config.apiKey}',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );
      request.contentLength = prefix.length + bytes.length + suffix.length;
      request.add(prefix);
      request.add(bytes);
      request.add(suffix);
      final response = await request.close().timeout(
        _deepSeekUploadTimeout,
        onTimeout: () {
          request.abort();
          throw TimeoutException('DeepSeek Files API response headers');
        },
      );
      final status = response.statusCode;
      if (_closed || status < 200 || status >= 300) {
        await response.listen(null).cancel();
        if (_closed) throw _cancelled;
        throw _deepSeekUploadFailure(status);
      }
      final result = BytesBuilder();
      await for (final chunk in response.timeout(_ioTimeout)) {
        if (result.length + chunk.length > _deepSeekFileResponseLimit) {
          throw _invalidDeepSeekFile;
        }
        result.add(chunk);
      }
      final payload = jsonDecode(utf8.decode(result.takeBytes()));
      final id = payload is Json ? payload['id'] : null;
      if (id is! String || _deepSeekFileIdPattern.stringMatch(id) != id) {
        throw _invalidDeepSeekFile;
      }
      final serverExpiry = (payload as Json)['expires_at'];
      final expiry = serverExpiry is int
          ? min(expiresAt, serverExpiry)
          : expiresAt;
      if (expiry <= _unixSeconds()) throw _invalidDeepSeekFile;
      return (id: id, expiresAt: expiry);
    } on _ProviderFailure {
      rethrow;
    } on TimeoutException {
      throw const _ProviderFailure('等待 DeepSeek 上传或解析 PDF 超时。');
    } on FormatException {
      throw _invalidDeepSeekFile;
    } catch (_) {
      throw const _ProviderFailure('无法连接 DeepSeek PDF 文件服务。');
    }
  }
}

Uri _endpoint(AgentModelConfig config) {
  final base = config.baseUrl;
  if (base.scheme != 'https' ||
      base.host.isEmpty ||
      base.authority.contains('@') ||
      base.hasQuery ||
      base.hasFragment ||
      base.port < 1 ||
      base.port > 65535 ||
      base.toString().length > 2048) {
    throw const _ProviderFailure('模型 API 地址必须是有效的 HTTPS 地址，且不能包含凭据、查询或片段。');
  }
  final prefix = base.pathSegments.toList();
  while (prefix.isNotEmpty && prefix.last.isEmpty) {
    prefix.removeLast();
  }
  return base.replace(
    pathSegments: [
      ...prefix,
      ...switch (config.provider) {
        ModelProvider.openAi => const ['chat', 'completions'],
        ModelProvider.anthropic => const ['messages'],
      },
    ],
  );
}

Uri? _deepSeekChatEndpoint(Uri uri, ModelProvider provider) =>
    switch ((provider, uri.path)) {
      (ModelProvider.openAi, '/chat/completions' || '/v1/chat/completions') =>
        uri.replace(path: '/chat/completions'),
      (
        ModelProvider.anthropic,
        '/anthropic/messages' || '/anthropic/v1/messages',
      ) =>
        uri.replace(path: '/anthropic/v1/messages'),
      _ => null,
    };

bool _supportsDeepSeekPdf(AgentModelConfig config) =>
    const {
      'deepseek-flash',
      'deepseek-v4-flash',
      'deepseek-v4-flash-vision-exp',
    }.contains(config.model) ||
    (config.provider == ModelProvider.anthropic &&
        config.model.startsWith('claude') &&
        !config.model.startsWith('claude-opus'));

int _unixSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void _validateRequest(
  AgentModelConfig config,
  List<AgentMessage> messages,
  List<AgentToolSpec> tools,
) {
  if (config.apiKey.isEmpty ||
      config.apiKey.length > 4096 ||
      config.apiKey.codeUnits.any((unit) => unit <= 32 || unit >= 127) ||
      config.model.trim().isEmpty) {
    throw const _ProviderFailure('请检查模型名称和 API 密钥。');
  }
  if (messages.length > _maxBlocks ||
      tools.length > _maxBlocks ||
      messages.any((message) => message.calls.length > _maxBlocks)) {
    throw _requestTooLarge;
  }
}

Future<Uint8List> _requestBody(
  AgentModelConfig config,
  List<AgentMessage> messages,
  List<AgentToolSpec> tools,
  Expando<List<Json>> anthropicBlocks,
  int requestLimit,
  Map<AgentAttachment, Json> fileSources, {
  required bool deepSeek,
  Future<void> Function()? uploadFiles,
}) async {
  try {
    final openAi = config.provider == ModelProvider.openAi;
    final payload = {
      'model': config.model,
      'stream': true,
      if (openAi && !deepSeek)
        'max_completion_tokens': _maxOutputTokens
      else
        'max_tokens': _maxOutputTokens,
      // Thinking mode requires replaying all reasoning during tool rounds.
      if (deepSeek) 'thinking': {'type': 'disabled'},
      if (!openAi) 'system': agentSystemPrompt,
      'messages': openAi
          ? _openAiMessages(messages, fileSources)
          : _anthropicMessages(messages, anthropicBlocks, fileSources),
      if (tools.isNotEmpty)
        'tools': [
          for (final tool in tools)
            if (openAi)
              {
                'type': 'function',
                'function': {
                  'name': tool.name,
                  'description': tool.description,
                  'parameters': tool.inputSchema,
                },
              }
            else
              {
                'name': tool.name,
                'description': tool.description,
                'input_schema': tool.inputSchema,
              },
        ],
    };
    final body = _encodeJson(payload, requestLimit);
    if (uploadFiles == null) return body;
    await uploadFiles();
    return _encodeJson(payload, requestLimit);
  } on _ProviderFailure {
    rethrow;
  } catch (_) {
    throw const _ProviderFailure('模型请求包含无法编码的对话或工具数据。');
  }
}

int _attachmentRequestLimit(
  List<AgentMessage> messages,
  Map<AgentAttachment, Uint8List>? deepSeekPdfs,
) {
  var attachmentCount = 0;
  var deepSeekPdfCount = 0;
  final limit =
      messages.any(
        (message) => message.attachments.any(
          (file) => file.maxBytes == agentMaxCampusPdfBytes,
        ),
      )
      ? _maxCampusPdfRequestBytes
      : _maxAttachmentRequestBytes;
  var remainingBytes = limit;
  for (final message in messages) {
    attachmentCount += message.attachments.length;
    if (attachmentCount > _maxBlocks) throw _requestTooLarge;
    for (final attachment in message.attachments) {
      if (deepSeekPdfs != null && attachment.mimeType == 'application/pdf') {
        if (++deepSeekPdfCount > 20) throw _requestTooLarge;
      }
      // Bound the content before building data URLs and encoding the envelope.
      remainingBytes -= _validateAttachment(
        attachment,
        remainingBytes,
        deepSeekPdfs,
      );
    }
  }
  return attachmentCount == 0 ? _maxRequestBytes : limit;
}

int _validateAttachment(
  AgentAttachment attachment,
  int remainingBytes,
  Map<AgentAttachment, Uint8List>? deepSeekPdfs,
) {
  if (attachment.name.trim().isEmpty) throw _invalidAttachment;
  final mimeType = attachment.mimeType;
  if (_textAttachmentMimeTypes.contains(mimeType)) {
    final text = attachment.text;
    if (text == null) throw _invalidAttachment;
    if (text.length > agentMaxTextAttachmentBytes) throw _attachmentTooLarge;
    final length = utf8.encode(text).length;
    if (length > agentMaxTextAttachmentBytes) throw _attachmentTooLarge;
    if (length > remainingBytes) throw _requestTooLarge;
    return length;
  }

  const signatures = <String, List<int>>{
    'image/jpeg': [0xff, 0xd8, 0xff],
    'image/png': [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
    'image/webp': [0x52, 0x49, 0x46, 0x46], // RIFF
    'application/pdf': [0x25, 0x50, 0x44, 0x46, 0x2d], // %PDF-
  };
  final signature = signatures[mimeType];
  if (signature == null) throw _invalidAttachment;

  final data = attachment.base64Data;
  final maxEncodedLength = (attachment.maxBytes + 2) ~/ 3 * 4;
  if (data.length > maxEncodedLength) throw _attachmentTooLarge;
  if (data.length > remainingBytes) throw _requestTooLarge;
  final Uint8List bytes;
  try {
    if (base64.normalize(data) != data) throw _invalidAttachment;
    bytes = base64Decode(data);
  } on FormatException {
    throw _invalidAttachment;
  }
  if (bytes.length > attachment.maxBytes) throw _attachmentTooLarge;
  if (!_matchesSignature(bytes, signature) ||
      (mimeType == 'image/webp' &&
          !_matchesSignature(bytes, const [0x57, 0x45, 0x42, 0x50], 8))) {
    throw _invalidAttachment;
  }
  if (mimeType == 'application/pdf') deepSeekPdfs?[attachment] = bytes;
  return data.length;
}

bool _matchesSignature(List<int> bytes, List<int> signature, [int offset = 0]) {
  if (bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

List<Json> _userContentBlocks(
  AgentMessage message,
  ModelProvider provider,
  Map<AgentAttachment, Json> fileSources,
) => [
  if (message.text.isNotEmpty) {'type': 'text', 'text': message.text},
  for (final attachment in message.attachments)
    _attachmentBlock(attachment, provider, fileSources[attachment]),
];

String _textAttachmentContent(AgentAttachment attachment) =>
    '文件数据 ${jsonEncode(attachment.name)}\n${attachment.text}';

Json _attachmentBlock(
  AgentAttachment attachment,
  ModelProvider provider,
  Json? fileSource,
) {
  if (fileSource != null) {
    return switch (provider) {
      ModelProvider.openAi => fileSource,
      ModelProvider.anthropic => {'type': 'document', 'source': fileSource},
    };
  }
  final mimeType = attachment.mimeType;
  if (_textAttachmentMimeTypes.contains(mimeType)) {
    return {'type': 'text', 'text': _textAttachmentContent(attachment)};
  }

  final pdf = mimeType == 'application/pdf';
  if (provider == ModelProvider.anthropic) {
    return {
      'type': pdf ? 'document' : 'image',
      if (pdf) 'title': attachment.name,
      'source': {
        'type': 'base64',
        'media_type': mimeType,
        'data': attachment.base64Data,
      },
    };
  }

  final dataUrl = 'data:$mimeType;base64,${attachment.base64Data}';
  return pdf
      ? {
          'type': 'file',
          'file': {'filename': attachment.name, 'file_data': dataUrl},
        }
      : {
          'type': 'image_url',
          'image_url': {'url': dataUrl},
        };
}

Object _openAiUserContent(
  AgentMessage message,
  Map<AgentAttachment, Json> fileSources,
) {
  if (message.attachments.isEmpty) return message.text;
  if (message.attachments.every(
    (attachment) => _textAttachmentMimeTypes.contains(attachment.mimeType),
  )) {
    // Some Chat Completions-compatible text endpoints accept only string content.
    return [
      if (message.text.isNotEmpty) message.text,
      ...message.attachments.map(_textAttachmentContent),
    ].join('\n\n');
  }
  return _userContentBlocks(message, ModelProvider.openAi, fileSources);
}

List<Json> _openAiMessages(
  List<AgentMessage> messages,
  Map<AgentAttachment, Json> fileSources,
) {
  var remainingArgumentBytes = _maxRequestBytes;

  String arguments(AgentToolCall call) {
    // The runner can replay its error result even if the original input was malformed.
    final bytes = _encodeJson(
      call.arguments ?? const <String, dynamic>{},
      remainingArgumentBytes,
    );
    remainingArgumentBytes -= bytes.length;
    return utf8.decode(bytes);
  }

  return [
    {'role': 'system', 'content': agentSystemPrompt},
    for (final message in messages)
      switch (message.role) {
        AgentRole.user => {
          'role': 'user',
          'content': _openAiUserContent(message, fileSources),
        },
        AgentRole.assistant => {
          'role': 'assistant',
          'content': message.text.isEmpty && message.calls.isNotEmpty
              ? null
              : message.text,
          if (message.calls.isNotEmpty)
            'tool_calls': [
              for (final call in message.calls)
                {
                  'id': call.id,
                  'type': 'function',
                  'function': {'name': call.name, 'arguments': arguments(call)},
                },
            ],
        },
        AgentRole.tool => {
          'role': 'tool',
          'tool_call_id': _resultId(message),
          'content': message.text,
        },
      },
  ];
}

List<Json> _anthropicMessages(
  List<AgentMessage> messages,
  Expando<List<Json>> replayBlocks,
  Map<AgentAttachment, Json> fileSources,
) {
  final history = <Json>[];
  List<Json>? results;
  for (final message in messages) {
    switch (message.role) {
      case AgentRole.user:
        if (results != null) {
          results.addAll(
            _userContentBlocks(message, ModelProvider.anthropic, fileSources),
          );
        } else {
          history.add({
            'role': 'user',
            'content': message.attachments.isEmpty
                ? message.text
                : _userContentBlocks(
                    message,
                    ModelProvider.anthropic,
                    fileSources,
                  ),
          });
        }
        results = null;
      case AgentRole.assistant:
        if (message.text.isEmpty && message.calls.isEmpty) continue;
        history.add({
          'role': 'assistant',
          'content':
              replayBlocks[message] ??
              [
                if (message.text.isNotEmpty)
                  {'type': 'text', 'text': message.text},
                ...message.calls.map(_anthropicToolUse),
              ],
        });
        results = null;
      case AgentRole.tool:
        if (results == null) {
          results = <Json>[];
          history.add({'role': 'user', 'content': results});
        }
        results.add({
          'type': 'tool_result',
          'tool_use_id': _resultId(message),
          'content': message.text,
        });
    }
  }
  return history;
}

Json _anthropicToolUse(AgentToolCall call) => {
  'type': 'tool_use',
  'id': call.id,
  'name': call.name,
  'input': call.arguments ?? const <String, dynamic>{},
};

String _resultId(AgentMessage message) {
  final id = message.toolCallId;
  if (id == null || id.isEmpty) {
    throw const _ProviderFailure('模型对话包含未关联到工具调用的结果。');
  }
  return id;
}

Uint8List _encodeJson(Object value, int byteLimit) {
  final output = _RequestBytes(byteLimit);
  JsonUtf8Encoder(
    null,
    (_) => throw const FormatException(),
  ).startChunkedConversion(output).add(value);
  return output.bytes.takeBytes();
}

class _RequestBytes implements Sink<List<int>> {
  _RequestBytes(this.limit);

  final int limit;
  final bytes = BytesBuilder();

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) throw _requestTooLarge;
    bytes.add(data);
  }

  @override
  void close() {}
}

typedef _SseEvent = ({String? name, String data});

Stream<_SseEvent> _sseEvents(Stream<List<int>> stream) async* {
  var received = 0;
  final lines = stream
      .map((chunk) {
        received += chunk.length;
        if (received > _maxStreamBytes) {
          throw const _ProviderFailure('模型响应流超过大小上限。');
        }
        return chunk;
      })
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  String? name;
  var data = StringBuffer();
  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final payload = data.toString();
        yield (name: name, data: payload.substring(0, payload.length - 1));
      }
      name = null;
      data = StringBuffer();
      continue;
    }
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    if (field != 'event' && field != 'data') continue;
    final start = colon < 0 ? line.length : colon + 1;
    final value = line.substring(
      start < line.length && line.codeUnitAt(start) == 32 ? start + 1 : start,
    );
    if (field == 'event') {
      name = value;
    } else {
      data.writeln(value);
    }
  }
  // An event without its blank line never completes, including at EOF.
  if (data.isNotEmpty || name != null) throw _truncatedStream;
}

Future<AgentMessage> _readOpenAi(
  Stream<_SseEvent> events,
  _AssistantTurn turn,
) async {
  String? finish;
  var done = false;
  var refused = false;
  await for (final event in events) {
    if (event.data == '[DONE]' && event.name != 'error') {
      done = true;
      break;
    }
    final chunk = _object(jsonDecode(event.data));
    if (event.name == 'error' ||
        chunk['type'] == 'error' ||
        chunk['error'] != null) {
      throw _streamFailure(chunk);
    }
    final choices = _array(chunk['choices']);
    if (choices.isEmpty) continue;
    if (choices.length != 1 || finish != null) throw _invalidStream;
    final choice = _object(choices.single);
    if (choice['index'] != 0) throw _invalidStream;
    final delta = _object(choice['delta'] ?? const <String, dynamic>{});
    if (delta['function_call'] != null) {
      throw const _ProviderFailure('模型使用了旧版函数调用协议。');
    }
    turn.addText(_optionalString(delta['content']));
    refused |= _optionalString(delta['refusal'])?.isNotEmpty ?? false;
    if (delta['tool_calls'] case final Object calls) {
      for (final value in _array(calls)) {
        final call = _object(value);
        if (call['type'] != null && call['type'] != 'function') {
          throw _invalidStream;
        }
        final input = turn.tools.putIfAbsent(_index(call), _ToolInput.new);
        final function = _object(call['function'] ?? const <String, dynamic>{});
        input.id = _metadata(input.id, call['id']);
        input.name = _metadata(input.name, function['name']);
        input.fragments.write(_optionalString(function['arguments']) ?? '');
      }
    }
    finish = _optionalString(choice['finish_reason']);
  }
  if (!done) throw _truncatedStream;
  return switch (finish) {
    null => throw _truncatedStream,
    'length' => throw _tokenLimit,
    'content_filter' => throw _refusal,
    'function_call' => throw const _ProviderFailure('模型使用了旧版函数调用协议。'),
    'stop' || 'tool_calls' =>
      refused
          ? throw _refusal
          : turn.finish(expectsTools: finish == 'tool_calls'),
    _ => throw _unsupportedStop,
  };
}

Future<AgentMessage> _readAnthropic(
  Stream<_SseEvent> events,
  _AssistantTurn turn,
  Expando<List<Json>> replayBlocks,
) async {
  final blocks = <int, _AnthropicBlock>{};
  var activeBlocks = 0;
  var started = false;
  String? finish;
  await for (final event in events) {
    final payload = _object(jsonDecode(event.data));
    final type = _requiredString(payload['type']);
    if (event.name == 'error' || type == 'error') throw _streamFailure(payload);
    if (event.name != null && event.name != type) throw _invalidStream;
    switch (type) {
      case 'message_start':
        if (started) throw _invalidStream;
        started = true;
      case 'content_block_start':
        final index = _index(payload);
        if (!started || finish != null || blocks.containsKey(index)) {
          throw _invalidStream;
        }
        final initial = _object(payload['content_block']);
        final block = _AnthropicBlock(initial);
        blocks[index] = block;
        activeBlocks++;
        if (block.kind == 'text') {
          block.addText(_optionalString(initial['text']), turn);
        } else if (block.kind == 'thinking') {
          block.text.write(_optionalString(initial['thinking']) ?? '');
          block.signature.write(_optionalString(initial['signature']) ?? '');
        } else if (block.kind == 'tool_use') {
          final input = initial['input'];
          turn.tools[index] = _ToolInput()
            ..id = _requiredString(initial['id'])
            ..name = _requiredString(initial['name'])
            ..initial = input is Json ? input : null;
        }
      case 'content_block_delta':
        final index = _index(payload);
        final block = blocks[index];
        if (block == null || block.stopped) throw _invalidStream;
        final delta = _object(payload['delta']);
        switch (_requiredString(delta['type'])) {
          case 'text_delta':
            if (block.kind != 'text') throw _invalidStream;
            block.addText(_optionalString(delta['text']), turn);
          case 'input_json_delta':
            if (block.kind == 'tool_use') {
              turn.tools[index]!.fragments.write(
                _optionalString(delta['partial_json']) ?? '',
              );
            } else if (block.kind == 'text' || block.kind == 'thinking') {
              throw _invalidStream;
            }
          case 'thinking_delta':
            if (block.kind != 'thinking') throw _invalidStream;
            block.text.write(_optionalString(delta['thinking']) ?? '');
          case 'signature_delta':
            if (block.kind != 'thinking') throw _invalidStream;
            block.signature.write(_requiredString(delta['signature']));
        }
      case 'content_block_stop':
        final block = blocks[_index(payload)];
        if (block == null || block.stopped) throw _invalidStream;
        block.stopped = true;
        activeBlocks--;
      case 'message_delta':
        if (!started || activeBlocks != 0) throw _invalidStream;
        final reason = _optionalString(
          _object(payload['delta'])['stop_reason'],
        );
        if (reason != null) {
          if (finish != null && finish != reason) throw _invalidStream;
          finish = reason;
        }
      case 'message_stop':
        if (!started || activeBlocks != 0 || finish == null) {
          throw _truncatedStream;
        }
        final reply = switch (finish) {
          'end_turn' || 'stop_sequence' => turn.finish(expectsTools: false),
          'tool_use' => turn.finish(expectsTools: true),
          'max_tokens' => throw _tokenLimit,
          'model_context_window_exceeded' => throw const _ProviderFailure(
            '模型达到上下文上限，响应不完整。',
          ),
          'refusal' => throw _refusal,
          'pause_turn' => throw const _ProviderFailure('模型暂停响应，需要继续服务端工具流程。'),
          _ => throw _unsupportedStop,
        };
        if (reply.calls.isNotEmpty) {
          replayBlocks[reply] = _anthropicReplay(blocks, reply.calls);
        }
        return reply;
    }
  }
  throw _truncatedStream;
}

List<Json> _anthropicReplay(
  Map<int, _AnthropicBlock> blocks,
  List<AgentToolCall> calls,
) {
  final callsById = {for (final call in calls) call.id: call};
  final indices = blocks.keys.toList()..sort();
  final replay = <Json>[];
  for (final index in indices) {
    final block = blocks[index]!;
    final content = switch (block.kind) {
      'text' when block.text.isNotEmpty => {
        'type': 'text',
        'text': block.text.toString(),
      },
      'tool_use' => _anthropicToolUse(callsById[block.initial['id']]!),
      'thinking' => {
        'type': 'thinking',
        'thinking': block.text.toString(),
        'signature': _requiredString(block.signature.toString()),
      },
      'redacted_thinking' => {
        'type': 'redacted_thinking',
        'data': _requiredString(block.initial['data']),
      },
      _ => null,
    };
    if (content != null) replay.add(content);
  }
  return replay;
}

class _AnthropicBlock {
  _AnthropicBlock(this.initial) : kind = _requiredString(initial['type']);

  final Json initial;
  final String kind;
  final text = StringBuffer();
  final signature = StringBuffer();
  bool stopped = false;

  void addText(String? delta, _AssistantTurn turn) {
    if (delta == null || delta.isEmpty) return;
    text.write(delta);
    turn.addText(delta);
  }
}

class _AssistantTurn {
  _AssistantTurn(this.onText);

  final void Function(String) onText;
  final text = StringBuffer();
  final tools = <int, _ToolInput>{};

  void addText(String? delta) {
    if (delta == null || delta.isEmpty) return;
    text.write(delta);
    onText(delta);
  }

  AgentMessage finish({required bool expectsTools}) {
    if (tools.isNotEmpty != expectsTools) throw _invalidStream;
    final indices = tools.keys.toList()..sort();
    final calls = <AgentToolCall>[];
    final ids = <String>{};
    for (final index in indices) {
      final input = tools[index]!;
      final id = _requiredString(input.id);
      if (!ids.add(id)) throw _invalidStream;
      calls.add(
        AgentToolCall(id, _requiredString(input.name), input.arguments()),
      );
    }
    return AgentMessage.assistant(text.toString(), calls);
  }
}

class _ToolInput {
  String? id;
  String? name;
  Json? initial;
  final fragments = StringBuffer();

  Json? arguments() {
    if (fragments.isEmpty) return initial;
    try {
      final decoded = jsonDecode(fragments.toString());
      return decoded is Json ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

Json _object(Object? value) => value is Json ? value : throw _invalidStream;

List<Object?> _array(Object? value) =>
    value is List<Object?> ? value : throw _invalidStream;

String? _optionalString(Object? value) =>
    value == null || value is String ? value as String? : throw _invalidStream;

String _requiredString(Object? value) =>
    value is String && value.isNotEmpty ? value : throw _invalidStream;

int _index(Json value) {
  final index = value['index'];
  return index is int && index >= 0 && index < _maxBlocks
      ? index
      : throw _invalidStream;
}

String? _metadata(String? previous, Object? value) {
  final next = _optionalString(value);
  if (next == null) return previous;
  if (previous != null && next != previous) throw _invalidStream;
  return next;
}

class _ProviderFailure implements Exception {
  const _ProviderFailure(this.message);

  final String message;
}

const _requestTooLarge = _ProviderFailure('模型请求超过大小上限，请缩短对话或减少工具。');
const _attachmentTooLarge = _ProviderFailure('附件超过大小上限。');
const _invalidAttachment = _ProviderFailure('附件格式无效或不受支持。');
const _invalidDeepSeekFile = _ProviderFailure('DeepSeek 返回的 PDF 文件信息无效或已过期。');
const _invalidStream = _ProviderFailure('模型服务返回的流格式无效。');
const _truncatedStream = _ProviderFailure('模型响应流在完整结束前中断。');
const _tokenLimit = _ProviderFailure('模型达到输出长度上限，响应不完整。');
const _refusal = _ProviderFailure('模型拒绝生成或过滤了响应。');
const _unsupportedStop = _ProviderFailure('模型返回了无法处理的结束原因。');

_ProviderFailure _deepSeekUploadFailure(int status) =>
    _ProviderFailure(switch (status) {
      400 => 'DeepSeek 无法解析 PDF。请检查文件是否损坏或受密码保护 (HTTP 400)。',
      401 || 403 => 'DeepSeek PDF 文件服务认证失败或权限不足 (HTTP $status)。',
      >= 300 && < 400 => 'DeepSeek PDF 文件服务尝试重定向 (HTTP $status)。',
      _ => 'DeepSeek PDF 上传或解析失败 (HTTP $status)。',
    });

_ProviderFailure _httpFailure(int status) => _ProviderFailure(switch (status) {
  >= 300 && < 400 => '模型服务尝试重定向 (HTTP $status)。',
  400 || 422 => '模型服务拒绝了请求格式或参数 (HTTP $status)。',
  401 || 403 => '模型服务认证失败或权限不足 (HTTP $status)。',
  404 => '模型服务找不到 API 路径或模型 (HTTP 404)。',
  413 => '模型服务拒绝了过大的请求 (HTTP 413)。',
  429 => '模型服务达到速率或配额限制 (HTTP 429)。',
  529 => '模型服务繁忙 (HTTP 529)。',
  >= 500 && <= 599 => '模型服务暂时不可用 (HTTP $status)。',
  _ => '模型服务返回 HTTP $status。',
});

_ProviderFailure _streamFailure(Json payload) {
  final error = payload['error'];
  final type = error is Json ? error['code'] ?? error['type'] : null;
  return switch (type) {
    'overloaded_error' ||
    'server_error' ||
    'api_error' => const _ProviderFailure('模型服务繁忙或暂时不可用。'),
    'rate_limit_error' ||
    'rate_limit_exceeded' ||
    'insufficient_quota' => const _ProviderFailure('模型服务达到速率或配额限制。'),
    'authentication_error' ||
    'permission_error' ||
    'invalid_api_key' => const _ProviderFailure('模型服务认证失败或权限不足。'),
    _ => const _ProviderFailure('模型服务在生成过程中报告错误。'),
  };
}
