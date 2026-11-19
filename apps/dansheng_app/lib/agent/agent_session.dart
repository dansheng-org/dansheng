// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'agent_campus_link.dart';
import 'agent_types.dart';

/// Each registered capability performs a bounded read with validated input.
class AgentTool {
  const AgentTool({
    required this.spec,
    required this.source,
    required this.label,
    required this.read,
    this.timeout,
  });

  final AgentToolSpec spec;
  final AgentSourceKind source;
  final String label;
  final Future<Json> Function(Json arguments) read;
  final Duration? timeout;

  bool accepts(Json? arguments) {
    if (arguments == null) return false;
    final properties = spec.inputSchema['properties'] as Json;
    final required = spec.inputSchema['required'] as List? ?? const [];
    if (required.any((key) => !arguments.containsKey(key))) return false;
    return arguments.entries.every((entry) {
      final field = properties[entry.key];
      if (field is! Json) return false;
      final value = entry.value;
      return switch (field['type']) {
        'boolean' => value is bool,
        'integer' =>
          value is int &&
              (field['minimum'] == null ||
                  value >= (field['minimum'] as int)) &&
              (field['maximum'] == null || value <= (field['maximum'] as int)),
        'string' =>
          value is String &&
              value.trim().isNotEmpty &&
              value.length <= (field['maxLength'] as int? ?? 160) &&
              (field['enum'] == null ||
                  (field['enum'] as List).contains(value)),
        _ => false,
      };
    });
  }
}

/// Protocol-neutral catalog. A caller can list and resolve only allowed tools.
class AgentToolRegistry {
  AgentToolRegistry({
    required Iterable<AgentTool> tools,
    required this.activeAccount,
    required this.sourceAvailable,
  }) : _tools = {for (final tool in tools) tool.spec.name: tool};

  final Map<String, AgentTool> _tools;
  final String? Function() activeAccount;
  final bool Function(AgentSourceKind) sourceAvailable;

  Iterable<AgentTool> forSources(Set<AgentSourceKind> sources) =>
      _tools.values.where(
        (tool) => sources.contains(tool.source) && sourceAvailable(tool.source),
      );
}

class AgentSession {
  AgentSession({
    required this._model,
    required this._registry,
    Iterable<({String question, String answer})> history = const [],
  }) {
    for (final turn in history) {
      _remember(
        AgentMessage.user(turn.question),
        AgentMessage.assistant(turn.answer),
      );
    }
  }

  static const _maxCalls = 20;
  static const _maxToolRounds = 8;
  static const _maxToolResultBytes = 56 * 1024;
  static const _maxHistoryBytes = 28 * 1024;
  final AgentModel _model;
  final AgentToolRegistry _registry;
  final _history = <AgentMessage>[];
  bool _closed = false;
  bool _busy = false;

  void _remember(AgentMessage user, AgentMessage reply) {
    final replyBytes = utf8.encode(reply.text);
    final available = _maxHistoryBytes - utf8.encode(user.text).length;
    if (replyBytes.length > available && available >= 64) {
      // Keep the start and the conclusion of an unusually long response.
      const separator = '\n\n［中段已省略］\n\n';
      var head = (available - utf8.encode(separator).length) ~/ 2;
      var tail = replyBytes.length - head;
      while ((replyBytes[head] & 0xc0) == 0x80) {
        head--;
      }
      while ((replyBytes[tail] & 0xc0) == 0x80) {
        tail++;
      }
      reply = AgentMessage.assistant(
        '${utf8.decode(replyBytes.sublist(0, head))}$separator'
        '${utf8.decode(replyBytes.sublist(tail))}',
      );
    }
    _history.addAll([user, reply]);
    while (_history.length > 20 ||
        _history.fold(
              0,
              (length, message) => length + utf8.encode(message.text).length,
            ) >
            _maxHistoryBytes) {
      _history.removeRange(0, 2);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _history.clear();
    _model.close();
  }

  Future<String> send(
    String text, {
    required Set<AgentSourceKind> sources,
    required Future<bool> Function(AgentSourceKind source) approve,
    required void Function(String delta) onText,
    required void Function(String label) onTool,
    List<AgentAttachment> attachments = const [],
    Future<bool> Function(String query)? approveWebSearch,
    void Function(Iterable<AgentWebLink> links)? onWebLinks,
    void Function(Iterable<AgentCampusLink> links)? onCampusLinks,
    void Function(AgentAttachment file)? onRemoteAttachment,
    void Function()? onRemembered,
  }) async {
    if (_closed || _busy) throw const AgentFailure('当前无法发送，请稍后再试。');
    if ((text.trim().isEmpty && attachments.isEmpty) || text.length > 4000) {
      throw const AgentFailure('请输入消息或添加附件。消息最多 4000 个字符。');
    }
    var attachmentLimit = agentAttachmentBudget(attachments);
    if (attachments.length > agentMaxAttachments ||
        attachments.any((file) => !_canAttach(file)) ||
        attachments.fold(0, (size, file) => size + file.byteLength) >
            attachmentLimit) {
      throw AgentFailure(
        '每条消息最多附加 3 个文件，总大小不得超过 ${attachmentLimit ~/ (1024 * 1024)} MiB。',
      );
    }
    _busy = true;
    final account = _registry.activeAccount();
    void checkSession() {
      if (_closed || _registry.activeAccount() != account) {
        throw const AgentFailure('本轮对话已结束。');
      }
    }

    final enabled = {
      for (final tool in _registry.forSources(sources))
        if (tool.source.requiresAccount
            ? (account?.isNotEmpty ?? false)
            : approveWebSearch != null)
          tool.spec.name: tool,
    };
    final decisions = <AgentSourceKind, bool>{};
    final webResults = <String, Json>{};
    final user = AgentMessage.user(
      text,
      attachments: List.unmodifiable(attachments),
    );
    final messages = [..._history, user];
    final answer = StringBuffer();
    final usedSources = <AgentSourceKind>{};
    var callCount = 0;
    var toolRounds = 0;
    var toolResultBytes = 0;
    var retriedAnswer = false;
    var hasAnswerText = false;
    var attachmentCount = attachments.length;
    var attachmentBytes = attachments.fold(
      0,
      (size, file) => size + file.byteLength,
    );
    try {
      while (true) {
        checkSession();
        if (usedSources.any((source) => !_registry.sourceAvailable(source))) {
          throw const AgentFailure('本轮信息源已停用。');
        }
        final finalOnly =
            retriedAnswer ||
            toolRounds >= _maxToolRounds ||
            callCount >= _maxCalls;
        final tools = finalOnly
            ? <String, AgentTool>{}
            : {
                for (final entry in enabled.entries)
                  if (_registry.sourceAvailable(entry.value.source))
                    entry.key: entry.value,
              };
        var streamedText = false;
        final reply = await _model.complete(
          messages: List.unmodifiable(messages),
          tools: [for (final tool in tools.values) tool.spec],
          onText: (delta) {
            checkSession();
            if (delta.isEmpty) return;
            if (!streamedText && answer.isNotEmpty) onText('\n\n');
            streamedText = true;
            onText(delta);
          },
        );
        checkSession();
        if (reply.text.isNotEmpty) {
          if (!streamedText) {
            if (answer.isNotEmpty) onText('\n\n');
            onText(reply.text);
          }
          if (answer.isNotEmpty) answer.write('\n\n');
          answer.write(reply.text);
        }
        if (reply.calls.isEmpty) {
          hasAnswerText |= reply.text.trim().isNotEmpty;
          if (!retriedAnswer && (reply.outputTruncated || !hasAnswerText)) {
            retriedAnswer = true;
            if (reply.text.trim().isNotEmpty) messages.add(reply);
            messages.add(
              AgentMessage.user(
                hasAnswerText
                    ? '请从中断处继续直接作答，不重复已给出的内容。'
                    : '请根据已有信息直接回答最初的问题；如果缺少必要信息，请说明具体缺少什么。',
              ),
            );
            continue;
          }
          if (hasAnswerText) {
            // Only the answer shown in the transcript follows the next turn.
            // Local files, provider reasoning, and structured tool rows are not replayed.
            _remember(
              AgentMessage.user(user.text),
              AgentMessage.assistant(answer.toString()),
            );
            onRemembered?.call();
          }
          if (reply.outputTruncated) {
            throw const AgentFailure('模型达到输出上限。你可以回复「继续」接着问。');
          }
          if (!hasAnswerText || (retriedAnswer && reply.text.trim().isEmpty)) {
            throw const AgentFailure('模型未生成有效回答。请降低推理强度或重试。');
          }
          return answer.toString();
        }
        callCount += reply.calls.length;
        if (callCount > _maxCalls || finalOnly) {
          throw const AgentFailure('已达到本轮查询上限，请缩小查询范围。');
        }
        toolRounds++;
        messages.add(reply);
        final remoteFiles = <AgentAttachment>[];
        for (final call in reply.calls) {
          final tool = tools[call.name];
          Json result = {'error': '本轮没有启用此工具。'};
          if (tool != null && _registry.sourceAvailable(tool.source)) {
            if (!tool.accepts(call.arguments)) {
              result = {'error': '工具参数无效。'};
            } else {
              final args = call.arguments!;
              final query = tool.source == AgentSourceKind.web
                  ? (args['query'] as String).trim()
                  : null;
              if (webResults[query] case final Json previous) {
                result = previous;
              } else if (query != null && webResults.length >= 3) {
                result = {'error': '本轮已达到网页搜索次数上限。'};
              } else {
                final allowed = query == null
                    ? (decisions[tool.source] ??= await approve(tool.source))
                    : await approveWebSearch!(query);
                checkSession();
                if (allowed && _registry.sourceAvailable(tool.source)) {
                  onTool(tool.label);
                  try {
                    result = await tool
                        .read(args)
                        .timeout(
                          tool.timeout ??
                              Duration(
                                seconds: tool.source.isRemoteFileSource
                                    ? 80
                                    : 35,
                              ),
                        );
                  } on TimeoutException {
                    result = {'error': '${tool.source.label}查询超时。'};
                  } on AgentFailure catch (e) {
                    result = {'error': e.message};
                  } catch (_) {
                    result = {'error': '${tool.source.label}查询失败。'};
                  }
                  checkSession();
                  usedSources.add(tool.source);
                  if (result['campus_links'] case final List links) {
                    onCampusLinks?.call(
                      links
                          .whereType<Json>()
                          .map(AgentCampusLink.fromJson)
                          .whereType<AgentCampusLink>(),
                    );
                  }
                  if (result['web_links'] case final List links) {
                    onWebLinks?.call(
                      links
                          .whereType<Json>()
                          .map(AgentWebLink.fromJson)
                          .whereType<AgentWebLink>(),
                    );
                  }
                } else {
                  result = {'error': '本轮未授权共享此信息源。'};
                }
                if (query != null) {
                  webResults[query] = result;
                  if (result['records'] case final List records) {
                    onWebLinks?.call(
                      records
                          .whereType<Json>()
                          .map(AgentWebLink.fromJson)
                          .whereType<AgentWebLink>(),
                    );
                  }
                }
              }
            }
          }
          if (result.containsKey('attachment')) {
            result = Map.of(result);
            final file = result.remove('attachment');
            final nextLimit = max(
              attachmentLimit,
              file is AgentAttachment ? file.maxBytes : 0,
            );
            if (file is! AgentAttachment ||
                tool?.source.isRemoteFileSource != true ||
                !_canAttach(file)) {
              result = {'error': '工具返回的文件附件无效或超出大小上限。'};
            } else if (attachmentCount >= agentMaxAttachments ||
                attachmentBytes + file.byteLength > nextLimit) {
              result = {'error': '本轮附件已达到数量或大小上限。请缩小文件范围。'};
            } else {
              attachmentCount++;
              attachmentLimit = nextLimit;
              attachmentBytes += file.byteLength;
              remoteFiles.add(file);
              onRemoteAttachment?.call(file);
            }
          }
          final encoded = jsonEncode(result);
          final size = utf8.encode(encoded).length;
          final fits =
              encoded.length <= 12000 &&
              toolResultBytes + size <= _maxToolResultBytes;
          if (fits) toolResultBytes += size;
          messages.add(
            AgentMessage.tool(
              call.id,
              fits ? encoded : '{"error":"工具结果超出本轮上下文限额，请缩小查询范围。"}',
            ),
          );
        }
        if (remoteFiles.isNotEmpty) {
          messages.add(
            AgentMessage.user(
              '以下是为本轮问题读取的文件内容。',
              attachments: List.unmodifiable(remoteFiles),
            ),
          );
        }
      }
    } finally {
      _busy = false;
    }
  }
}

bool _canAttach(AgentAttachment file) {
  final size = file.byteLength;
  if (!isAgentAttachmentType(file.mimeType) ||
      size <= 0 ||
      size > file.maxBytes) {
    return false;
  }
  if (!file.isText) return true;
  final text = file.text;
  return size <= agentMaxTextAttachmentBytes &&
      text != null &&
      text.isNotEmpty &&
      text.length <= agentMaxTextAttachmentBytes &&
      utf8.encode(text).length <= agentMaxTextAttachmentBytes;
}
