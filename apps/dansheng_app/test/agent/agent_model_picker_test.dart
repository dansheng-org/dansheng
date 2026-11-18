// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:dansheng_app/agent/model_catalog.dart';
import 'package:dansheng_app/ui/campus/agent/agent_model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads on open, retries a failure, and returns a model ID', (
    tester,
  ) async {
    final firstLoad = Completer<List<ModelCatalogEntry>>();
    var calls = 0;
    final selection = await _openPicker(
      tester,
      AgentModelPicker(
        selectedId: 'current-id',
        load: () {
          calls++;
          if (calls == 1) return firstLoad.future;
          return Future.value(const [
            ModelCatalogEntry('current-id', label: 'Current model'),
            ModelCatalogEntry('other-id', label: 'Different name'),
          ]);
        },
      ),
    );

    expect(calls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    firstLoad.completeError(StateError('private fixture error'));
    await tester.pumpAndSettle();
    expect(find.text('无法读取模型列表。'), findsOneWidget);
    expect(find.textContaining('private fixture error'), findsNothing);

    await tester.tap(find.byTooltip('重试读取模型列表'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('当前'), findsOneWidget);
    final search = find.byType(TextField);
    await tester.enterText(search, 'CURRENT-ID');
    await tester.pump();
    expect(find.text('Different name'), findsNothing);
    await tester.enterText(search, 'different NAME');
    await tester.pump();
    expect(find.text('当前'), findsNothing);
    await tester.tap(find.text('Different name'));
    await tester.pumpAndSettle();
    final chosen = await selection.future;
    expect(chosen?.id, 'other-id');
    expect(chosen?.label, 'Different name');
  });

  testWidgets('uses a seeded catalog and allows manual input during refresh', (
    tester,
  ) async {
    final refresh = Completer<List<ModelCatalogEntry>>();
    var calls = 0;
    final selection = await _openPicker(
      tester,
      AgentModelPicker(
        selectedId: 'seeded-id',
        initialModels: const [ModelCatalogEntry('seeded-id')],
        load: () {
          calls++;
          return refresh.future;
        },
      ),
    );

    expect(calls, 0);
    expect(find.text('seeded-id'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新模型列表'));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('seeded-id'), findsOneWidget);

    await tester.tap(find.text('手动输入'));
    await tester.pump();
    final input = find.byType(TextField);
    final submit = find.text('选择');
    await tester.enterText(input, '  ');
    await tester.tap(submit);
    await tester.pump();
    expect(find.text('请输入服务商提供的模型标识。'), findsOneWidget);
    await tester.enterText(input, '  custom/model  ');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect((await selection.future)?.id, 'custom/model');

    refresh.complete(const [ModelCatalogEntry('later-id')]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<Completer<ModelCatalogEntry?>> _openPicker(
  WidgetTester tester,
  AgentModelPicker picker,
) async {
  final selection = Completer<ModelCatalogEntry?>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selection.complete(
                await Navigator.of(context).push(
                  DialogRoute<ModelCatalogEntry>(
                    context: context,
                    builder: (_) => picker,
                  ),
                ),
              );
            },
            child: const Text('打开模型选择'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开模型选择'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  return selection;
}
