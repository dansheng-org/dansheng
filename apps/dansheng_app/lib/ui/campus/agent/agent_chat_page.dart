// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../agent/agent_campus_link.dart';
import '../../../agent/agent_history.dart';
import '../../../agent/agent_session.dart';
import '../../../agent/agent_types.dart';
import '../../../agent/model_catalog.dart';
import '../../../agent/model_providers.dart';
import '../../../agent/provider_web_search.dart';
import '../../../agent/web_search.dart';
import '../../core/dansheng_state.dart';
import '../campus_api.dart';
import 'agent_approval_store.dart';
import 'agent_approvals_dialog.dart';
import 'agent_answer_content.dart';
import 'agent_attachment_picker.dart';
import 'agent_campus_navigation.dart';
import 'agent_chat_composer.dart';
import 'agent_chat_settings.dart';
import 'agent_cloud_attachment_picker.dart';
import 'agent_course_files.dart';
import 'agent_history_dialog.dart';
import 'agent_history_store.dart';
import 'agent_model_picker.dart';
import 'agent_settings_store.dart';
import 'agent_tools.dart';

class AgentChatPage extends StatefulWidget {
  const AgentChatPage({
    super.key,
    required this.controller,
    required this.onOpenLocal,
    this.createModel = StreamingAgentModel.new,
    this.loadModels,
  });

  final DanshengController controller;
  final VoidCallback onOpenLocal;
  final AgentModel Function(AgentModelConfig config) createModel;
  final ModelCatalogLoader? loadModels;

  @override
  State<AgentChatPage> createState() => _AgentChatPageState();
}

class _ChatTurn {
  _ChatTurn(this.question, this.attachmentNames, {this.model, this.destination})
    : remember = false;

  _ChatTurn.restore(AgentHistoryTurn turn)
    : question = turn.question,
      attachmentNames = turn.attachments,
      model = turn.model,
      destination = turn.destination,
      remember = turn.remember,
      answer = turn.answer,
      notice = turn.notice ?? (turn.answer == null ? '上次生成已中断。' : null) {
    for (final link in turn.webLinks) {
      webLinks[link.uri] = link;
    }
    for (final link in turn.campusLinks) {
      campusLinks[link.uri] = link;
    }
  }

  final String question;
  final List<String> attachmentNames;
  final String? model;
  final String? destination;
  final webLinks = <Uri, AgentWebLink>{};
  final campusLinks = <Uri, AgentCampusLink>{};
  final streamedAnswer = StringBuffer();
  String? answer;
  String? notice;
  bool remember;

  AgentHistoryTurn get snapshot => AgentHistoryTurn(
    question: question,
    answer: answer,
    notice: notice,
    model: model,
    destination: destination,
    remember: remember,
    attachments: List.unmodifiable(attachmentNames),
    webLinks: List.unmodifiable(webLinks.values),
    campusLinks: List.unmodifiable(campusLinks.values),
  );
}

typedef _AccountState = ({String? id, int generation, bool changing});

enum _ShareChoice { once, always }

class _AgentChatPageState extends State<AgentChatPage> {
  final _draft = TextEditingController();
  final _scroll = ScrollController();
  final _sources = <AgentSourceKind>{};
  final _turns = <_ChatTurn>[];
  final _attachments = <AgentAttachment>[];
  var _draftGeneration = 0;
  bool _pickingAttachment = false;
  late AgentSettingsStore _store;
  late AgentHistoryStore _historyStore;
  late AgentApprovalStore _approvalStore;
  Future<void> _historyQueue = Future.value();
  final _savedConversationIds = <String>{};
  String? _conversationId;
  String? _conversationTitle;
  int _conversationUpdatedAt = 0;
  String? _historySaveError;
  DialogRoute<String>? _historyRoute;
  int _historyLoadRequest = 0;
  DialogRoute<ModelCatalogEntry>? _modelRoute;
  DialogRoute<void>? _grantsRoute;
  ModalBottomSheetRoute<AgentComposerAction>? _composerRoute;
  MaterialPageRoute<AgentAttachment>? _cloudAttachmentRoute;
  DialogRoute<String>? _editRoute;
  bool _savingConfig = false;
  late _AccountState _account;
  AgentModelConfig? _config;
  bool _loading = true;
  bool _loadFailed = false;
  AgentSession? _session;
  CampusApi? _sessionApi;
  _ChatTurn? _activeTurn;
  _ChatTurn? _replacedTurn;
  String? _toolLabel;
  DialogRoute<_ShareChoice>? _approvalRoute;
  MaterialPageRoute<void>? _settingsRoute;

  _AccountState get _currentAccount => (
    id: widget.controller.activeAccountId,
    generation: widget.controller.accountGeneration,
    changing: widget.controller.isChangingAccount,
  );

  @override
  void initState() {
    super.initState();
    _account = _currentAccount;
    widget.controller.addListener(_accountChanged);
    _store = AgentSettingsStore(widget.controller.client);
    _historyStore = AgentHistoryStore(widget.controller.client);
    _approvalStore = AgentApprovalStore(widget.controller.client);
    unawaited(_loadConfig());
  }

  @override
  void didUpdateWidget(covariant AgentChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_accountChanged);
    _account = _currentAccount;
    widget.controller.addListener(_accountChanged);
    _closeAccountDialogs();
    _clearConversation();
    if (oldWidget.controller.client != widget.controller.client) {
      _closeSettings();
      _config = null;
      _loading = true;
      _loadFailed = false;
      _store = AgentSettingsStore(widget.controller.client);
      _historyStore = AgentHistoryStore(widget.controller.client);
      _approvalStore = AgentApprovalStore(widget.controller.client);
      _savedConversationIds.clear();
      unawaited(_loadConfig());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_accountChanged);
    _closeSession();
    _closeSettings();
    _closeAccountDialogs();
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _accountChanged() {
    final account = _currentAccount;
    final crossedBoundary = account != _account;
    final forumDisabled =
        !widget.controller.forumEnabled &&
        _sources.contains(AgentSourceKind.forum);
    if (!crossedBoundary && !forumDisabled) return;
    setState(() {
      _account = account;
      if (crossedBoundary) {
        _closeAccountDialogs();
        _clearConversation();
      }
      if (forumDisabled) _sources.remove(AgentSourceKind.forum);
    });
  }

  Future<void> _loadConfig() async {
    final store = _store;
    try {
      final config = await store.load();
      if (!mounted || !identical(store, _store)) return;
      setState(() {
        _config = config;
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (!mounted || !identical(store, _store)) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  // A controller notification or disposal can happen while the navigator is
  // updating its routes. Remove only the route owned by this chat.
  void _dismissRoute(Route<dynamic>? route) {
    if (route == null) return;
    scheduleMicrotask(() {
      final navigator = route.navigator;
      if (navigator != null && navigator.mounted && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  void _closeSettings() {
    final route = _settingsRoute;
    _settingsRoute = null;
    _dismissRoute(route);
  }

  void _closeAccountDialogs() {
    _dismissRoute(_historyRoute);
    _dismissRoute(_modelRoute);
    _dismissRoute(_grantsRoute);
    _dismissRoute(_composerRoute);
    _dismissRoute(_cloudAttachmentRoute);
    _dismissRoute(_editRoute);
    _historyRoute = null;
    _modelRoute = null;
    _grantsRoute = null;
    _composerRoute = null;
    _cloudAttachmentRoute = null;
    _editRoute = null;
  }

  void _closeSession() {
    final session = _session;
    final scope = _sessionApi?.accountScope;
    final approval = _approvalRoute;
    _session = null;
    _sessionApi = null;
    _activeTurn = null;
    _replacedTurn = null;
    _toolLabel = null;
    _approvalRoute = null;
    session?.close();
    scope?.dispose();
    _dismissRoute(approval);
  }

  void _clearConversation() {
    _closeSession();
    _turns.clear();
    _conversationId = null;
    _conversationTitle = null;
    _conversationUpdatedAt = 0;
    _historySaveError = null;
    _sources.clear();
    _attachments.clear();
    _draftGeneration++;
    _draft.clear();
  }

  void _stop() {
    final turn = _activeTurn;
    if (turn == null) return;
    setState(() {
      if (_replacedTurn case final original?) {
        _turns[_turns.length - 1] = original;
        _closeSession();
        return;
      }
      if (turn.streamedAnswer.isNotEmpty) {
        turn.answer = turn.streamedAnswer.toString();
        turn.streamedAnswer.clear();
      }
      _closeSession();
      turn.notice = '已停止生成。';
    });
    unawaited(_saveConversation());
  }

  void _newConversation() {
    _stop();
    setState(_clearConversation);
  }

  Future<T> _withHistory<T>(
    _AccountState scope,
    Future<T> Function(AgentHistoryStore store) action,
  ) {
    final store = _historyStore;
    final operation = _historyQueue.then((_) async {
      if (!mounted ||
          scope != _currentAccount ||
          !identical(store, _historyStore)) {
        throw const AgentFailure('账号已切换，请重新打开对话历史。');
      }
      return action(store);
    });
    _historyQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _identifyConversation(_ChatTurn firstTurn) {
    if (_conversationId != null) return;
    final random = Random.secure();
    _conversationId = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final title = firstTurn.question.trim().replaceAll(RegExp(r'\s+'), ' ');
    final fallback = firstTurn.attachmentNames.firstOrNull ?? '新对话';
    _conversationTitle = String.fromCharCodes(
      (title.isEmpty ? fallback : title).runes.take(36),
    );
  }

  Future<void> _saveConversation() async {
    final id = _conversationId;
    if (id == null ||
        _turns.isEmpty ||
        _replacedTurn != null ||
        _currentAccount != _account ||
        _account.changing) {
      return;
    }
    final scope = _account;
    _conversationUpdatedAt = max(
      DateTime.now().millisecondsSinceEpoch,
      _conversationUpdatedAt + 1,
    );
    final conversation = AgentConversation(
      id: id,
      title: _conversationTitle!,
      updatedAt: _conversationUpdatedAt,
      turns: List.unmodifiable(_turns.map((turn) => turn.snapshot)),
    );
    bool isCurrent() =>
        mounted &&
        _currentAccount == scope &&
        _conversationId == id &&
        _conversationUpdatedAt == conversation.updatedAt;
    try {
      await _withHistory(scope, (store) async {
        await store.save(
          scope.id,
          conversation,
          create: !_savedConversationIds.contains(id),
        );
        _savedConversationIds.add(id);
      });
      if (isCurrent() && _historySaveError != null) {
        setState(() => _historySaveError = null);
      }
    } catch (error) {
      if (isCurrent()) {
        setState(
          () => _historySaveError = error is AgentFailure
              ? error.message
              : '对话未能保存。',
        );
      }
    }
  }

  Future<void> _openHistory() async {
    if (_historyRoute != null || _activeTurn != null || _account.changing) {
      return;
    }
    FocusScope.of(context).unfocus();
    final request = ++_historyLoadRequest;
    final scope = _account;
    final route = DialogRoute<String>(
      context: context,
      builder: (_) => AgentHistoryDialog(
        selectedId: _conversationId,
        load: () => _withHistory(scope, (store) => store.list(scope.id)),
        rename: (chat, title) async {
          final updated = max(
            DateTime.now().millisecondsSinceEpoch,
            chat.updatedAt + 1,
          );
          await _withHistory(
            scope,
            (store) => store.rename(scope.id, chat.id, title, updated),
          );
          if (mounted &&
              scope == _currentAccount &&
              _conversationId == chat.id) {
            setState(() {
              _conversationTitle = title;
              _conversationUpdatedAt = updated;
            });
          }
        },
        delete: (chat) async {
          await _withHistory(scope, (store) => store.delete(scope.id, chat.id));
          _savedConversationIds.remove(chat.id);
          if (mounted &&
              scope == _currentAccount &&
              _conversationId == chat.id) {
            setState(_clearConversation);
          }
        },
      ),
    );
    _historyRoute = route;
    final id = await Navigator.of(context).push(route);
    if (!identical(_historyRoute, route)) return;
    _historyRoute = null;
    if (id == null ||
        id == _conversationId ||
        !mounted ||
        scope != _currentAccount) {
      return;
    }
    final generation = _draftGeneration;
    try {
      final chat = await _withHistory(
        scope,
        (store) => store.get(scope.id, id),
      );
      if (!mounted ||
          scope != _currentAccount ||
          request != _historyLoadRequest ||
          generation != _draftGeneration ||
          _activeTurn != null) {
        return;
      }
      if (chat == null) throw const AgentFailure('这条对话已删除。');
      setState(() {
        _clearConversation();
        _savedConversationIds.add(chat.id);
        _conversationId = chat.id;
        _conversationTitle = chat.title;
        _conversationUpdatedAt = chat.updatedAt;
        _turns.addAll(chat.turns.map(_ChatTurn.restore));
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (error) {
      if (mounted && scope == _currentAccount) {
        final message = error is AgentFailure ? error.message : '无法打开这条对话。';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  String _destination(AgentModelConfig config) =>
      '${config.provider.name}:${normalizeModelApiPrefix(config.baseUrl, provider: config.provider)}';

  Future<void> _pickModel() async {
    final config = _config;
    if (config == null || !_canEditComposer || _modelRoute != null) {
      return;
    }
    FocusScope.of(context).unfocus();
    ModelCatalog? catalog;
    final route = DialogRoute<ModelCatalogEntry>(
      context: context,
      builder: (_) => AgentModelPicker(
        selectedId: config.model,
        load: () {
          catalog?.close();
          final loader = widget.loadModels ?? (catalog = ModelCatalog()).load;
          return loader(
            provider: config.provider,
            baseUrl: config.baseUrl,
            apiKey: config.apiKey,
          );
        },
      ),
    );
    _modelRoute = route;
    ModelCatalogEntry? model;
    try {
      model = await Navigator.of(context).push(route);
    } finally {
      catalog?.close();
    }
    if (!identical(_modelRoute, route)) return;
    _modelRoute = null;
    if (!mounted || !identical(_config, config) || model == null) return;
    final label =
        model.label ?? (model.id == config.model ? config.modelLabel : null);
    if (model.id == config.model && label == config.modelLabel) return;
    await _saveComposerConfig(
      AgentModelConfig(
        provider: config.provider,
        baseUrl: config.baseUrl,
        model: model.id,
        modelLabel: label,
        apiKey: config.apiKey,
        searchApiKey: config.searchApiKey,
        reasoningEffort: config.reasoningEffort,
      ),
      '无法切换模型，请重试。',
    );
  }

  Future<void> _selectReasoning(AgentReasoningEffort effort) async {
    final config = _config;
    if (config == null ||
        !_canEditComposer ||
        effort == config.reasoningEffort) {
      return;
    }
    await _saveComposerConfig(
      AgentModelConfig(
        provider: config.provider,
        baseUrl: config.baseUrl,
        model: config.model,
        modelLabel: config.modelLabel,
        apiKey: config.apiKey,
        searchApiKey: config.searchApiKey,
        reasoningEffort: effort,
      ),
      '无法保存推理强度，请重试。',
    );
  }

  Future<void> _saveComposerConfig(
    AgentModelConfig updated,
    String error,
  ) async {
    final store = _store;
    setState(() => _savingConfig = true);
    try {
      await store.save(updated);
      if (!mounted || !identical(store, _store)) return;
      setState(() {
        _closeSession();
        _config = updated;
      });
    } catch (_) {
      if (mounted && identical(store, _store)) _showNotice(error);
    } finally {
      if (mounted) setState(() => _savingConfig = false);
    }
  }

  Future<void> _openSettings() async {
    if (_settingsRoute != null || _loading || _savingConfig) return;
    _stop();
    final store = _store;
    final scope = _account;
    Future<void> update(AgentModelConfig? config) async {
      if (config == null) {
        await store.clear();
      } else {
        await store.save(config);
      }
      if (!mounted || !identical(store, _store)) return;
      setState(() {
        _closeSession();
        if (_config != null &&
            (config == null ||
                _destination(_config!) != _destination(config))) {
          _attachments.clear();
          _sources.clear();
          _draftGeneration++;
        }
        _config = config;
        _loadFailed = false;
      });
    }

    final route = MaterialPageRoute<void>(
      builder: (_) => AgentChatSettings(
        config: _config,
        canClear: _config != null || _loadFailed,
        onSave: update,
        onClear: () => update(null),
        loadModels: widget.loadModels,
        onClearRemoteFiles: scope.id == null
            ? null
            : () async {
                if (!mounted || _currentAccount != scope) {
                  throw const AgentFailure('账号已切换，请重新打开模型设置。');
                }
                final api = CampusApi.forAccount(widget.controller);
                try {
                  return await clearAgentRemoteFiles(api);
                } finally {
                  api.accountScope!.dispose();
                }
              },
      ),
    );
    _settingsRoute = route;
    await Navigator.of(context).push(route);
    if (identical(_settingsRoute, route)) _settingsRoute = null;
  }

  AgentSession _startSession(AgentModelConfig config, {_ChatTurn? excluding}) {
    final api = CampusApi.forAccount(widget.controller);
    try {
      final registry = campusAgentTools(
        api,
        activeAccount: () => api.isCurrent ? api.accountScope!.accountId : null,
        forumEnabled: () => widget.controller.forumEnabled,
        webTool: switch (config.searchApiKey) {
          final String key when key.isNotEmpty => BraveWebSearch(key).tool,
          _ => ProviderWebSearch(config).tool,
        },
      );
      final session = AgentSession(
        model: widget.createModel(config),
        registry: registry,
        history: _turns
            .where(
              (turn) =>
                  !identical(turn, excluding) &&
                  turn.remember &&
                  turn.answer != null &&
                  turn.destination == _destination(config),
            )
            .map(
              (turn) => (
                question: turn.question.isEmpty ? '请分析所附文件。' : turn.question,
                answer: turn.answer!,
              ),
            ),
      );
      _session = session;
      _sessionApi = api;
      return session;
    } catch (_) {
      api.accountScope!.dispose();
      rethrow;
    }
  }

  bool _isActive(AgentSession session, _ChatTurn turn) =>
      mounted &&
      identical(_session, session) &&
      identical(_activeTurn, turn) &&
      _currentAccount == _account &&
      _sessionApi!.isCurrent;

  bool _sourceAvailable(AgentSourceKind source) =>
      !_currentAccount.changing &&
      (source.requiresAccount
          ? (_currentAccount.id?.isNotEmpty ?? false) &&
                (source != AgentSourceKind.forum ||
                    widget.controller.forumEnabled)
          : _config != null);

  bool get _canEditComposer =>
      _activeTurn == null &&
      !_account.changing &&
      !_pickingAttachment &&
      !_savingConfig;

  void _toggleWeb() {
    if (!_canEditComposer || !_sourceAvailable(AgentSourceKind.web)) return;
    setState(() {
      if (!_sources.remove(AgentSourceKind.web)) {
        _sources.add(AgentSourceKind.web);
      }
    });
  }

  Future<void> _openComposerOptions(AgentModelConfig config) async {
    if (!_canEditComposer || _composerRoute != null) return;
    final scope = _account;
    final generation = _draftGeneration;
    bool isCurrent() =>
        mounted &&
        scope == _currentAccount &&
        generation == _draftGeneration &&
        identical(config, _config) &&
        _canEditComposer;

    if (!isCurrent()) return;
    FocusScope.of(context).unfocus();
    final navigator = Navigator.of(context);
    final route = ModalBottomSheetRoute<AgentComposerAction>(
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ListenableBuilder(
        listenable: widget.controller,
        builder: (_, _) => StatefulBuilder(
          builder: (_, refreshSheet) => AgentComposerOptions(
            config: config,
            hasAccount: scope.id?.isNotEmpty ?? false,
            canAttach: isCurrent() && _attachments.length < agentMaxAttachments,
            sources: _sources,
            sourceAvailable: (source) =>
                isCurrent() && _sourceAvailable(source),
            onSourceChanged: (source, enabled) {
              if (!isCurrent() || !_sourceAvailable(source)) return;
              setState(() {
                if (enabled) {
                  _sources.add(source);
                } else {
                  _sources.remove(source);
                }
              });
              refreshSheet(() {});
            },
          ),
        ),
      ),
    );
    _composerRoute = route;
    final action = await navigator.push(route);
    if (!identical(_composerRoute, route)) return;
    _composerRoute = null;
    if (!isCurrent()) return;
    switch (action) {
      case AgentComposerAction.localAttachment:
        if (_attachments.length < agentMaxAttachments) await _pickAttachment();
      case AgentComposerAction.cloudAttachment:
        if (scope.id != null && _attachments.length < agentMaxAttachments) {
          await _pickAttachment(cloud: true);
        }
      case AgentComposerAction.manageApprovals:
        await _manageApprovals();
      case null:
        break;
    }
  }

  Future<void> _manageApprovals() async {
    final config = _config;
    if (config == null || _account.changing || _grantsRoute != null) return;
    final scope = _account;
    final store = _approvalStore;
    final destination = _destination(config);
    final route = DialogRoute<void>(
      context: context,
      builder: (_) => AgentApprovalsDialog(
        baseUrl: config.baseUrl,
        load: () => store.get(scope.id, destination),
        revoke: (permission) => store.revoke(scope.id, destination, permission),
        clear: () => store.clear(scope.id),
      ),
    );
    _grantsRoute = route;
    await Navigator.of(context).push(route);
    if (identical(_grantsRoute, route)) _grantsRoute = null;
  }

  Future<bool> _confirmShare(
    String title,
    String body,
    String action, {
    required AgentModelConfig config,
    required String permission,
    required bool Function() isActive,
  }) async {
    final scope = _account;
    final store = _approvalStore;
    final destination = _destination(config);
    bool isCurrent() =>
        mounted &&
        scope == _currentAccount &&
        identical(config, _config) &&
        identical(store, _approvalStore) &&
        isActive();
    bool canPrompt() =>
        isCurrent() &&
        _approvalRoute == null &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.isCurrentOf(context) != false;
    if (!canPrompt()) return false;
    try {
      final grants = await store.get(scope.id, destination);
      if (grants.contains(permission)) return canPrompt();
    } catch (_) {
      // A missing or unavailable persisted grant falls back to confirmation.
    }
    if (!mounted || !canPrompt()) return false;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final route = DialogRoute<_ShareChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SelectableText('$body\n\n始终允许仅适用于当前账号和模型地址，可在「管理授权」撤销。'),
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('拒绝'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ShareChoice.always),
            child: const Text('始终允许'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ShareChoice.once),
            child: Text(action),
          ),
        ],
      ),
    );
    _approvalRoute = route;
    final choice = await nav.push(route);
    if (!mounted || !identical(_approvalRoute, route)) return false;
    _approvalRoute = null;
    if (choice == null || !isCurrent()) return false;
    if (choice == _ShareChoice.always) {
      try {
        await store.allow(scope.id, destination, permission);
      } catch (_) {
        if (mounted && isCurrent()) {
          messenger.showSnackBar(
            const SnackBar(content: Text('本次已允许，长期授权未能保存。')),
          );
        }
      }
    }
    return mounted && isCurrent();
  }

  Future<bool> _approve(
    AgentSession session,
    _ChatTurn turn,
    AgentSourceKind source,
    AgentModelConfig config,
  ) async {
    if (!_isActive(session, turn) || !_sourceAvailable(source)) return false;
    final disclosure = switch (source) {
      AgentSourceKind.files => '允许查找课程、作业及其文件。相关名称和文件内容会发送至 ${config.baseUrl}。',
      AgentSourceKind.cloudFiles =>
        '允许列出和读取${source.label}。相关文件名及内容会发送至 ${config.baseUrl}。',
      _ => '查询结果将发送至 ${config.baseUrl}。',
    };
    final approved = await _confirmShare(
      '允许查询${source.label}？',
      '$disclosure\n\n原始资料仅发送本轮。已显示的问答可作为同一模型服务的后续对话上下文。',
      '仅本轮允许',
      config: config,
      permission: source.name,
      isActive: () => _isActive(session, turn) && _sourceAvailable(source),
    );
    return approved && _isActive(session, turn) && _sourceAvailable(source);
  }

  Future<bool> _approveWeb(
    AgentSession session,
    _ChatTurn turn,
    String query,
    AgentModelConfig config,
  ) async {
    if (!_isActive(session, turn) || !_sourceAvailable(AgentSourceKind.web)) {
      return false;
    }
    final brave = config.searchApiKey?.isNotEmpty ?? false;
    final approved = await _confirmShare(
      '搜索这些关键词？',
      brave
          ? '关键词将发送至 Brave Search，结果将发送至 ${config.baseUrl}。\n\n$query'
          : '这些关键词将交给 ${config.baseUrl} 的联网搜索功能。\n\n$query',
      '搜索',
      config: config,
      permission: brave ? AgentSourceKind.web.name : 'web_provider',
      isActive: () =>
          _isActive(session, turn) && _sourceAvailable(AgentSourceKind.web),
    );
    return approved &&
        _isActive(session, turn) &&
        _sourceAvailable(AgentSourceKind.web);
  }

  Future<void> _pickAttachment({bool cloud = false}) async {
    final generation = _draftGeneration;
    setState(() => _pickingAttachment = true);
    try {
      final attachment = cloud
          ? await _openCloudPicker()
          : await AgentAttachmentPicker(widget.controller.client).pick();
      if (!mounted || generation != _draftGeneration || attachment == null) {
        return;
      }
      final pending = [..._attachments, attachment];
      final size = pending.fold(0, (sum, item) => sum + item.byteLength);
      final limit = agentAttachmentBudget(pending);
      if (size > limit) {
        throw AgentFailure('每条消息的附件总大小不得超过 ${limit ~/ (1024 * 1024)} MiB。');
      }
      setState(() => _attachments.add(attachment));
    } on AgentFailure catch (error) {
      if (mounted && generation == _draftGeneration) {
        _showNotice(error.message);
      }
    } finally {
      if (mounted) setState(() => _pickingAttachment = false);
    }
  }

  Future<AgentAttachment?> _openCloudPicker() async {
    final api = CampusApi.forAccount(widget.controller);
    final route = MaterialPageRoute<AgentAttachment>(
      builder: (_) => AgentCloudAttachmentPicker(api: api),
    );
    _cloudAttachmentRoute = route;
    try {
      return await Navigator.of(context).push(route);
    } finally {
      api.accountScope!.dispose();
      if (identical(_cloudAttachmentRoute, route)) _cloudAttachmentRoute = null;
    }
  }

  Future<void> _openWebLink(AgentWebLink link) async {
    try {
      await CampusApi(widget.controller.client)
          .call('agent.web.open', {'url': link.uri.toString()});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开网页。')));
      }
    }
  }

  Future<void> _openCampusLink(AgentCampusLink link) async {
    if (_account.changing ||
        _currentAccount != _account ||
        _account.id == null) {
      return;
    }
    try {
      await openAgentCampusLink(context, widget.controller, link);
    } catch (error) {
      if (mounted) {
        final message = error is AgentFailure ? error.message : '无法打开这条校园记录。';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  bool _canReplay(_ChatTurn turn) {
    final config = _config;
    return config != null &&
        _canEditComposer &&
        _approvalRoute == null &&
        identical(_turns.lastOrNull, turn) &&
        turn.attachmentNames.isEmpty &&
        turn.question.trim().isNotEmpty &&
        turn.destination == _destination(config);
  }

  Future<void> _editQuestion(_ChatTurn turn) async {
    if (!_canReplay(turn) || _editRoute != null) return;
    final draft = TextEditingController(text: turn.question);
    final route = DialogRoute<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑消息'),
        scrollable: true,
        content: TextField(
          controller: draft,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 4000,
          decoration: const InputDecoration(labelText: '消息'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          ValueListenableBuilder(
            valueListenable: draft,
            builder: (_, value, _) => FilledButton(
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () {
                      final text = draft.text.trim();
                      if (text.isNotEmpty) {
                        Navigator.of(dialogContext).pop(text);
                      }
                    },
              child: const Text('重新发送'),
            ),
          ),
        ],
      ),
    );
    _editRoute = route;
    final edited = await Navigator.of(context).push(route);
    unawaited(route.completed.whenComplete(draft.dispose));
    if (!identical(_editRoute, route)) return;
    _editRoute = null;
    if (mounted && edited != null) await _send(replacing: turn, edited: edited);
  }

  void _showNotice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copyAnswer(String answer) async {
    final scope = _account;
    try {
      await Clipboard.setData(ClipboardData(text: answer));
      if (mounted && scope == _account) _showNotice('已复制回答');
    } catch (_) {
      if (mounted && scope == _account) _showNotice('无法复制回答，请重试。');
    }
  }

  Future<void> _send({_ChatTurn? replacing, String? edited}) async {
    final config = _config;
    final text = (edited ?? replacing?.question ?? _draft.text).trim();
    if (replacing != null && !_canReplay(replacing)) return;
    if (config == null ||
        _activeTurn != null ||
        _savingConfig ||
        _approvalRoute != null ||
        _pickingAttachment ||
        _currentAccount != _account ||
        _account.changing ||
        (text.isEmpty && _attachments.isEmpty)) {
      return;
    }
    final attachments = replacing == null
        ? List<AgentAttachment>.of(_attachments)
        : const <AgentAttachment>[];
    final names = attachments.map((item) => item.name).toList();
    if (attachments.isNotEmpty) {
      final generation = _draftGeneration;
      final approved = await _confirmShare(
        '发送附件？',
        '以下文件将随本轮对话发送至 ${config.baseUrl}。已显示的问答可作为该服务的后续上下文。\n\n${names.join('\n')}',
        '发送附件',
        config: config,
        permission: 'attachment',
        isActive: () => generation == _draftGeneration && _activeTurn == null,
      );
      if (!mounted ||
          !approved ||
          _activeTurn != null ||
          generation != _draftGeneration ||
          !identical(_config, config)) {
        return;
      }
    }
    final turn = _ChatTurn(
      text,
      names,
      model: config.displayModel,
      destination: _destination(config),
    );
    final sources = _sources.where(_sourceAvailable).toSet();
    final AgentSession session;
    try {
      if (replacing != null) _closeSession();
      session = _session ?? _startSession(config, excluding: replacing);
    } catch (_) {
      _showNotice('无法启动模型会话，请检查模型设置。');
      return;
    }
    FocusScope.of(context).unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _identifyConversation(turn);
      _replacedTurn = replacing;
      if (replacing == null) {
        _turns.add(turn);
        _draft.clear();
        _attachments.clear();
      } else {
        _turns[_turns.length - 1] = turn;
      }
      _activeTurn = turn;
    });

    try {
      if (replacing == null) await _saveConversation();
      if (!_isActive(session, turn)) return;
      final answer = await session.send(
        text.isEmpty ? '请分析所附文件。' : text,
        sources: sources,
        attachments: attachments,
        approve: (source) => _approve(session, turn, source, config),
        approveWebSearch: (query) => _approveWeb(session, turn, query, config),
        onRemembered: () {
          if (_isActive(session, turn)) turn.remember = true;
        },
        onWebLinks: (links) {
          if (!_isActive(session, turn)) return;
          setState(() {
            for (final link in links) {
              if (turn.webLinks.length < 24) turn.webLinks[link.uri] = link;
            }
          });
        },
        onCampusLinks: (links) {
          if (!_isActive(session, turn)) return;
          setState(() {
            for (final link in links) {
              if (turn.campusLinks.length < 24) {
                turn.campusLinks[link.uri] = link;
              }
            }
          });
        },
        onRemoteAttachment: (file) {
          if (_isActive(session, turn)) {
            setState(() => turn.attachmentNames.add(file.name));
          }
        },
        onText: (delta) {
          if (!_isActive(session, turn)) return;
          setState(() {
            turn.streamedAnswer.write(delta);
            _toolLabel = null;
          });
        },
        onTool: (label) {
          if (!_isActive(session, turn)) return;
          setState(() => _toolLabel = label);
        },
      );
      if (!_isActive(session, turn)) return;
      setState(() {
        turn.answer = answer;
        turn.streamedAnswer.clear();
        if (answer.isEmpty) turn.notice = '模型未返回文本。';
      });
    } on AgentFailure catch (error) {
      if (!_isActive(session, turn)) return;
      setState(() {
        if (turn.streamedAnswer.isNotEmpty) {
          turn.answer = turn.streamedAnswer.toString();
        }
        turn.notice = error.message;
      });
    } catch (_) {
      if (!_isActive(session, turn)) return;
      setState(() {
        if (turn.streamedAnswer.isNotEmpty) {
          turn.answer = turn.streamedAnswer.toString();
        }
        turn.notice = '模型请求失败，请稍后重试。';
      });
    } finally {
      if (_isActive(session, turn)) {
        setState(() {
          if (replacing != null && turn.notice != null) {
            _turns[_turns.length - 1] = replacing;
            _closeSession();
          } else {
            _replacedTurn = null;
            _activeTurn = null;
            _toolLabel = null;
          }
        });
        if (replacing != null && turn.notice != null) {
          _showNotice(turn.notice!);
        }
        unawaited(_saveConversation());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _conversationTitle ?? '校园助手',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: '新建对话',
            onPressed:
                _turns.isEmpty &&
                    _sources.isEmpty &&
                    _draft.text.isEmpty &&
                    _attachments.isEmpty
                ? null
                : _newConversation,
            icon: const Icon(Icons.edit_square),
          ),
          IconButton(
            tooltip: '对话历史',
            onPressed: _activeTurn != null || _account.changing
                ? null
                : _openHistory,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: '本地检索与配对',
            onPressed: _account.changing
                ? null
                : () {
                    _stop();
                    widget.onOpenLocal();
                  },
            icon: const Icon(Icons.manage_search),
          ),
          IconButton(
            tooltip: '模型设置',
            onPressed: _loading || _savingConfig ? null : _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: config == null && _turns.isEmpty
            ? _buildSetup()
            : LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    Expanded(child: _buildTranscript()),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * .85,
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        child: config == null
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: OutlinedButton(
                                  onPressed: _loading ? null : _openSettings,
                                  child: const Text('配置模型后继续对话'),
                                ),
                              )
                            : _buildComposer(config),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildSetup() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return _emptyState(
      _loadFailed ? '无法读取模型配置。' : '配置模型服务后即可开始对话。',
      FilledButton.icon(
        onPressed: _openSettings,
        icon: const Icon(Icons.settings_outlined),
        label: const Text('配置模型'),
      ),
    );
  }

  Widget _emptyState(String message, [Widget? action]) => Center(
    child: SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 12), action],
        ],
      ),
    ),
  );

  Widget _buildTranscript() {
    if (_turns.isEmpty) return _emptyState('输入消息开始对话。');
    final theme = Theme.of(context);
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.all(16),
      itemCount: _turns.length,
      itemBuilder: (context, index) {
        final turn = _turns[_turns.length - 1 - index];
        final active = identical(turn, _activeTurn);
        final answer = turn.answer ?? turn.streamedAnswer.toString();
        final canReplay = _canReplay(turn);
        return Padding(
          key: ObjectKey(turn),
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FractionallySizedBox(
                  widthFactor: .85,
                  alignment: AlignmentDirectional.centerEnd,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (turn.question.isNotEmpty)
                              SelectableText(
                                turn.question,
                                style: TextStyle(
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                                semanticsLabel: '你：${turn.question}',
                              ),
                            for (final name in turn.attachmentNames)
                              Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (canReplay)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: IconButton(
                    tooltip: '编辑上一条消息',
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => _editQuestion(turn),
                  ),
                ),
              if (answer.isNotEmpty) ...[
                const SizedBox(height: 12),
                if (turn.model case final String model)
                  Text(model, style: theme.textTheme.labelSmall),
                AgentAnswerContent(
                  data: answer,
                  onLink: (href) {
                    final uri = Uri.tryParse(href);
                    if (turn.campusLinks[uri] case final AgentCampusLink link) {
                      _openCampusLink(link);
                    } else if (turn.webLinks[uri]
                        case final AgentWebLink link) {
                      _openWebLink(link);
                    }
                  },
                ),
              ],
              if (turn.campusLinks.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('校园来源（${turn.campusLinks.length}）'),
                  initiallyExpanded: turn.campusLinks.length <= 3,
                  children: [
                    for (final link in turn.campusLinks.values)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          link.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openCampusLink(link),
                      ),
                  ],
                ),
              if (turn.webLinks.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('网页来源（${turn.webLinks.length}）'),
                  children: [
                    for (final link in turn.webLinks.values)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          link.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(link.uri.host),
                        trailing: const Icon(Icons.open_in_new),
                        onTap: () => _openWebLink(link),
                      ),
                  ],
                ),
              if (active || turn.notice != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    active ? (_toolLabel ?? '正在生成…') : turn.notice!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
              if (!active && (answer.isNotEmpty || canReplay))
                Wrap(
                  children: [
                    if (answer.isNotEmpty)
                      IconButton(
                        tooltip: '复制回答',
                        icon: const Icon(Icons.content_copy_outlined, size: 18),
                        onPressed: () => _copyAnswer(answer),
                      ),
                    if (canReplay)
                      IconButton(
                        tooltip: '重新生成',
                        icon: const Icon(Icons.refresh_rounded, size: 20),
                        onPressed: () => _send(replacing: turn),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildComposer(AgentModelConfig config) => AgentChatComposer(
    controller: _draft,
    config: config,
    attachments: _attachments,
    sourceCount: _sources.length,
    canEdit: _canEditComposer,
    generating: _activeTurn != null,
    switchingAccount: _account.changing,
    savingConfig: _savingConfig,
    pickingAttachment: _pickingAttachment,
    webEnabled: _sources.contains(AgentSourceKind.web),
    onChanged: () => setState(() {}),
    onOptions: () => _openComposerOptions(config),
    onModel: _pickModel,
    onReasoning: _selectReasoning,
    onToggleWeb: _toggleWeb,
    onDeleteAttachment: (file) => setState(() => _attachments.remove(file)),
    onSend:
        _canEditComposer &&
            (_draft.text.trim().isNotEmpty || _attachments.isNotEmpty)
        ? _send
        : null,
    onStop: _stop,
    historySaveError: _historySaveError,
    onRetrySave: _saveConversation,
  );
}
