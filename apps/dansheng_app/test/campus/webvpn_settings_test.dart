// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/webvpn_settings.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A host with one account's WebVPN routes and gateway session.
class _Host implements DanshengBridge {
  String mode = 'direct';
  int routes = 0;
  bool session = false;
  bool cancelLogin = false;
  final calls = <(String, Map)>[];

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    final params = request['params'] as Map;
    calls.add((method, params));
    switch (method) {
      case 'fudan.webvpn.status':
        return jsonEncode({
          'mode': mode,
          'enabled': routes > 0 && mode != 'direct',
          'has_session': session,
          'routes_count': routes,
        });
      case 'fudan.webvpn.configure':
        mode = params['mode'] as String;
        routes = 13;
        return jsonEncode({'configured': true, 'mode': mode});
      case 'campus.login':
        if (params['service'] != 'webvpn') break;
        if (cancelLogin) throw PlatformException(code: 'Cancelled');
        session = true;
        return jsonEncode({'connected': true});
    }
    throw PlatformException(code: 'MethodUnavailable');
  }
}

class _App extends DanshengController {
  _App(_Host host) : super(client: DanshengClient(bridge: host));
  @override
  String? get activeAccountId => '24300000000';
}

Future<void> _pump(WidgetTester tester, _App app) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: WebVpnSettingsCard(controller: app)),
    ),
  );
  await tester.pumpAndSettle();
}

SwitchListTile _switch(WidgetTester tester) =>
    tester.widget(find.byKey(const ValueKey('webvpn-switch')));

void main() {
  testWidgets('turning WebVPN on sends every Fudan service through it', (
    tester,
  ) async {
    final host = _Host();
    final app = _App(host);
    await _pump(tester, app);
    expect(_switch(tester).value, isFalse);

    await tester.tap(find.byKey(const ValueKey('webvpn-switch')));
    await tester.pumpAndSettle();
    expect(host.mode, 'gateway');
    expect(host.session, isTrue);
    expect(_switch(tester).value, isTrue);
    expect(find.textContaining('全部复旦服务经 WebVPN'), findsOneWidget);
    expect(find.textContaining('WebVPN 已登录'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('webvpn-switch')));
    await tester.pumpAndSettle();
    expect(host.mode, 'direct');
    expect(_switch(tester).value, isFalse);
    // Off never asks for a password.
    expect(host.calls.where((c) => c.$1 == 'campus.login'), hasLength(1));
    app.dispose();
  });

  testWidgets('an older fallback-only setting reads as partly on', (
    tester,
  ) async {
    final host = _Host()
      ..mode = 'auto'
      ..routes = 13
      ..session = true;
    final app = _App(host);
    await _pump(tester, app);
    expect(_switch(tester).value, isFalse);
    expect(find.textContaining('部分开启'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('webvpn-switch')));
    await tester.pumpAndSettle();
    expect(host.mode, 'gateway');
    expect(_switch(tester).value, isTrue);
    // A live WebVPN session needs no new password.
    expect(host.calls.where((c) => c.$1 == 'campus.login'), isEmpty);
    app.dispose();
  });

  testWidgets('a cancelled sign-in leaves routing on with a sign-in button', (
    tester,
  ) async {
    final host = _Host()..cancelLogin = true;
    final app = _App(host);
    await _pump(tester, app);
    await tester.tap(find.byKey(const ValueKey('webvpn-switch')));
    await tester.pumpAndSettle();
    expect(find.text('已取消。'), findsOneWidget);
    host.cancelLogin = false;
    await tester.tap(find.text('登录 WebVPN'));
    await tester.pumpAndSettle();
    expect(host.session, isTrue);
    expect(find.text('登录 WebVPN'), findsNothing);
    app.dispose();
  });
}
