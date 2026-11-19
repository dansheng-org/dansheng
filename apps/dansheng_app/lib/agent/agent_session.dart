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
  });

  final AgentToolSpec spec;
  final AgentSourceKind source;
  final String label;
  final Future<Json> Function(Json arguments) read;

  bool accepts(Json? arguments) {
    if (arguments == null) return false;
    final properties = spec.inputSchema['properties'] as Json;
    final required = spec.inputSchema['required'] as List;
    if (required.any((key) => !arguments.containsKey(key))) return false;
    return arguments.entries.every((entry) {
      final field = properties[entry.key];
      if (field is! Json) return false;
      final value = entry.value;
      return switch (field['type']) {
        'boolean' => value is bool,
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

  static const _maxCalls = 12;
  static const _maxRounds = 4;
  final AgentModel _model;
  final AgentToolRegistry _registry;
  final _history = <AgentMessage>[];
  bool _closed = false;
  bool _busy = false;

  void _remember(AgentMessage user, AgentMessage reply) {
    _history.addAll([user, reply]);
    while (_history.length > 12 ||
        _history.fold(0, (length, message) => length + message.text.length) >
            16000) {
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
    if (attachments.length > agentMaxAttachments ||
        attachments.any((file) => !_canAttach(file)) ||
        attachments.fold(0, (size, file) => size + file.byteLength) >
            agentMaxAttachmentBytes) {
      throw const AgentFailure('每条消息最多附加 3 个文件，总大小不得超过 2 MiB。');
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
    var attachmentCount = attachments.length;
    var attachmentLimit = agentMaxAttachmentBytes;
    var attachmentBytes = attachments.fold(
      0,
      (size, file) => size + file.byteLength,
    );
    try {
      for (var round = 0; round <= _maxRounds; round++) {
        checkSession();
        if (usedSources.any((source) => !_registry.sourceAvailable(source))) {
          throw const AgentFailure('本轮信息源已停用。');
        }
        final tools = (round == _maxRounds || callCount == _maxCalls)
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
          if (answer.isNotEmpty) answer.write('\n\n');
          answer.write(reply.text);
        }
        if (reply.calls.isEmpty) {
          if (callCount == 0 && attachments.isEmpty) {
            _remember(user, reply);
            if (reply.text.isNotEmpty) onRemembered?.call();
          }
          return answer.toString();
        }
        callCount += reply.calls.length;
        if (callCount > _maxCalls || round == _maxRounds) {
          throw const AgentFailure('已达到本轮查询上限，请缩小查询范围。');
        }
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
                          Duration(
                            seconds: tool.source.isRemoteFileSource ? 80 : 35,
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
          messages.add(
            AgentMessage.tool(
              call.id,
              encoded.length <= 12000 ? encoded : '{"error":"结果过大，请缩小查询范围。"}',
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
      throw const AgentFailure('已达到本轮查询上限，请缩小查询范围。');
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
