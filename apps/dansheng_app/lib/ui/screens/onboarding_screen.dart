import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../campus/campus_api.dart';
import '../core/dansheng_state.dart';

/// First-run setup, as DanXi's login guide: the UIS account first, then the
/// optional forum (DanXi/fduhole) account. Passwords are typed in the host's
/// own secure sheet and checked by a real sign-in; they never reach Dart.
/// Without a forum account the forum tab stays hidden.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    required this.onFinished,
  });

  final DanshengController controller;
  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final TextEditingController _account;
  int _step = 0;
  bool _busy = false;
  String? _error;

  static final _accountPattern = RegExp(r'^[A-Za-z0-9_.:@-]{1,128}$');

  @override
  void initState() {
    super.initState();
    _account = TextEditingController(
      text: widget.controller.activeAccountId ?? '',
    );
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  CampusApi get _api => CampusApi(widget.controller.client);

  bool _cancelled(Object e) => e is PlatformException
      ? e.code == 'Cancelled'
      : '$e'.contains('Cancelled');

  Future<void> _signInUis() async {
    final id = _account.text.trim();
    if (!_accountPattern.hasMatch(id)) {
      setState(() => _error = '请输入学号或工号');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (id != widget.controller.activeAccountId) {
        await widget.controller.switchAccount(id);
      }
      // The host asks for the UIS password and keeps it only if the school accepts it.
      await _api.call('campus.login', {'service': 'ecard', 'replace': true});
      await widget.controller.refreshLoginStatus();
      if (mounted) setState(() => _step = 1);
    } catch (e) {
      if (mounted && !_cancelled(e)) setState(() => _error = campusError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInForum() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Risk notice, then the forum e-mail and password, in the host's sheets.
      await _api.call('campus.login', {'service': 'forum', 'replace': true});
      await widget.controller.refreshLoginStatus();
      if (mounted) widget.onFinished();
    } catch (e) {
      if (mounted && !_cancelled(e)) setState(() => _error = campusError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skipForum() async {
    await widget.controller.refreshLoginStatus();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
                shrinkWrap: true,
                children: [
                  Icon(
                    _step == 0 ? Icons.school_outlined : Icons.forum_outlined,
                    size: 56,
                    color: colors.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _step == 0 ? '欢迎使用旦生' : '登录复旦树洞（可选）',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _step == 0
                        ? '先登录复旦大学统一身份认证（UIS）。密码在系统安全窗口中输入，'
                              '学校确认后加密保存在本机，之后各项服务自动保持登录。'
                        : '使用旦挲（DanXi）/ 树洞的注册邮箱和密码登录。'
                              '跳过则不显示论坛入口，之后可在“账号与卡包”中登录。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _StepDots(step: _step),
                  const SizedBox(height: 24),
                  if (_step == 0)
                    TextField(
                      key: const Key('onboarding-account'),
                      controller: _account,
                      enabled: !_busy,
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _signInUis(),
                      decoration: const InputDecoration(
                        labelText: '学号 / 工号',
                        prefixIcon: Icon(Icons.badge_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: Key(
                      _step == 0 ? 'onboarding-uis' : 'onboarding-forum',
                    ),
                    onPressed: _busy
                        ? null
                        : (_step == 0 ? _signInUis : _signInForum),
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_rounded),
                    label: Text(_step == 0 ? '输入密码并登录' : '登录树洞'),
                  ),
                  const SizedBox(height: 8),
                  if (_step == 0)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              widget.controller.deferSetup();
                              widget.onFinished();
                            },
                      child: const Text('暂不登录'),
                    )
                  else
                    TextButton(
                      key: const Key('onboarding-skip-forum'),
                      onPressed: _busy ? null : _skipForum,
                      child: const Text('跳过，不使用树洞'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 2; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == step ? 24 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == step ? colors.primary : colors.outlineVariant,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}
