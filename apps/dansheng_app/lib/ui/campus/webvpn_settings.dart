// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../core/dansheng_state.dart';
import 'campus_api.dart';

/// The account's WebVPN routing as the host reports it.
class WebVpnStatus {
  final bool enabled;
  final bool hasSession;

  /// `auto`, `gateway`, `direct` or `mixed`.
  final String mode;
  final int routes;

  const WebVpnStatus({
    required this.enabled,
    required this.hasSession,
    required this.mode,
    required this.routes,
  });

  factory WebVpnStatus.fromJson(dynamic json) {
    final map = json is Map ? json : const {};
    final routes = map['routes_count'];
    return WebVpnStatus(
      enabled: map['enabled'] == true,
      hasSession: map['has_session'] == true,
      mode: map['mode']?.toString() ?? 'direct',
      routes: routes is int ? routes : 0,
    );
  }
}

/// Turns WebVPN on, off, or into smart fallback for every fudan.edu.cn service.
/// On (`gateway`) sends each Fudan request and sign-in through WebVPN;
/// `auto` (智能回退) tries direct first and falls back to WebVPN on failure or
/// campus internal addresses; off (`direct`) sends none.
class WebVpnSettingsCard extends StatefulWidget {
  final DanshengController controller;
  const WebVpnSettingsCard({super.key, required this.controller});

  @override
  State<WebVpnSettingsCard> createState() => _WebVpnSettingsCardState();
}

class _WebVpnSettingsCardState extends State<WebVpnSettingsCard> {
  CampusApi? _api;
  String? _account;
  WebVpnStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_accountChanged);
    _accountChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_accountChanged);
    _api?.accountScope?.dispose();
    super.dispose();
  }

  void _accountChanged() {
    final account = widget.controller.activeAccountId;
    if (account == _account && (_api?.isCurrent ?? account == null)) return;
    _account = account;
    _api?.accountScope?.dispose();
    _api = null;
    _status = null;
    _error = null;
    if (account == null || account.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    _api = CampusApi.forAccount(widget.controller);
    _refresh();
  }

  Future<void> _run(Future<void> Function(CampusApi api) action) async {
    final api = _api;
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      try {
        await action(api);
      } catch (error) {
        if (mounted && identical(api, _api) && !isAccountChange(error)) {
          _error = campusError(error);
        }
      }
      // Re-read even after a failure: part of the change may have applied.
      final status = WebVpnStatus.fromJson(
        await api.call('fudan.webvpn.status'),
      );
      if (mounted && identical(api, _api)) _status = status;
    } catch (error) {
      if (mounted && identical(api, _api) && !isAccountChange(error)) {
        _error ??= campusError(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run((_) async {});

  Future<void> _setMode(String mode) => _run((api) async {
    await api.call('fudan.webvpn.configure', {'mode': mode});
    // Routing alone is not enough: the gateway needs its own sign-in.
    if (mode != 'direct') {
      final status = WebVpnStatus.fromJson(
        await api.call('fudan.webvpn.status'),
      );
      if (!status.hasSession) {
        await api.call('campus.login', {'service': 'webvpn'});
      }
    }
  });

  Future<void> _signIn() => _run(
    (api) => api.call('campus.login', {'service': 'webvpn', 'replace': true}),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = _status;
    final signedOut = _api == null;
    final on = status?.mode == 'gateway';
    final auto = status?.mode == 'auto';

    final String subtitle;
    if (signedOut) {
      subtitle = '登录校园账号后可设置';
    } else if (status == null) {
      subtitle = _busy ? '正在读取状态…' : '状态未知';
    } else if (on) {
      subtitle = [
        '全部复旦服务经 WebVPN',
        status.hasSession ? 'WebVPN 已登录' : 'WebVPN 未登录',
        '${status.routes} 个服务地址',
      ].join(' · ');
    } else if (auto) {
      subtitle = [
        '智能回退（部分开启）：直连优先，失败或内网时经 WebVPN',
        status.hasSession ? 'WebVPN 已登录' : 'WebVPN 未登录',
        '${status.routes} 个服务地址',
      ].join(' · ');
    } else {
      subtitle = status.enabled
          ? '部分开启：仅在直连失败时经 WebVPN，打开后全部复旦服务经 WebVPN'
          : '已关闭：复旦服务全部直连，校外可能无法访问内网服务';
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            key: const ValueKey('webvpn-switch'),
            secondary: Icon(
              Icons.vpn_lock_outlined,
              color: on || auto ? scheme.primary : scheme.outline,
            ),
            title: const Text('WebVPN 校外访问'),
            subtitle: Text(subtitle),
            value: on,
            onChanged: signedOut || _busy || status == null
                ? null
                : (value) => _setMode(value ? 'gateway' : 'direct'),
          ),
          if (!signedOut && status != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SegmentedButton<String>(
                key: const ValueKey('webvpn-mode-selector'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: 'direct',
                    label: Text('关闭'),
                    icon: Icon(Icons.power_settings_new, size: 16),
                  ),
                  ButtonSegment(
                    value: 'auto',
                    label: Text('智能回退'),
                    icon: Icon(Icons.alt_route, size: 16),
                  ),
                  ButtonSegment(
                    value: 'gateway',
                    label: Text('全部代理'),
                    icon: Icon(Icons.vpn_lock, size: 16),
                  ),
                ],
                selected: {
                  status.mode == 'mixed'
                      ? (status.enabled ? 'auto' : 'direct')
                      : (status.mode == 'gateway' || status.mode == 'auto'
                            ? status.mode
                            : 'direct'),
                },
                onSelectionChanged: _busy
                    ? null
                    : (selected) => _setMode(selected.first),
              ),
            ),
          if (status != null && status.mode != 'direct' && !status.hasSession)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _signIn,
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('登录 WebVPN'),
                ),
              ),
            ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: scheme.error, fontSize: 13),
                    ),
                  ),
                  TextButton(onPressed: _refresh, child: const Text('重试')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
