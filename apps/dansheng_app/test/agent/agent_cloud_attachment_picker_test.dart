// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:dansheng_app/agent/agent_types.dart';
import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/agent/agent_cloud_attachment_picker.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _pdf = utf8.encode('%PDF-1.7\noriginal fixture');
const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00];

void main() {
  testWidgets('filters the full course file listing and returns the PDF', (
    tester,
  ) async {
    final fixture = _Fixture(
      (method, params) => switch (method) {
        'canvas.courses.sync' => _courses,
        'canvas.materials.sync' => [
          for (var id = 1; id <= 30; id++)
            {
              'id': '$id',
              'filename': 'lecture-$id.pdf',
              'display_name': '讲义 $id',
            },
        ],
        'agent.remoteFile.read' => _asset(
          'lecture-30.pdf',
          'application/pdf',
          _pdf,
        ),
        _ => throw StateError(method),
      },
    );
    await fixture.open(tester);
    for (final label in ['eLearning', '芯片导论', '课程文件']) {
      await _tap(tester, label);
    }
    await tester.enterText(find.byType(TextField), 'LECTURE-30.PDF');
    await tester.pumpAndSettle();
    expect(find.text('讲义 1'), findsNothing);
    expect(fixture.downloads, isEmpty);
    await _tap(tester, '讲义 30');

    expect(fixture.downloads.single, {
      'source': 'canvas',
      'course_id': '42',
      'file_id': '30',
    });
    expect(fixture.result?.name, 'lecture-30.pdf');
    expect(fixture.result?.mimeType, 'application/pdf');
    expect(fixture.result?.text, isNull);
    expect(base64Decode(fixture.result!.base64Data), _pdf);
    expect(fixture.api.isCurrent, isTrue);
  });

  testWidgets('lists assignment PDFs, PNG, text and unnamed campus links', (
    tester,
  ) async {
    final fixture = _Fixture(
      (method, params) => switch (method) {
        'canvas.courses.sync' => _courses,
        'canvas.assignments.sync' => [
          {
            'id': '7',
            'name': 'Assignment 1',
            'description': '''
<a href="/courses/42/files/20/download?sig=fixture">说明.pdf</a>
<a data-api-endpoint="https://elearning.fudan.edu.cn/api/v1/files/21">电路.png</a>
<a href="/files/22">备注.txt</a>
<a href="/files/23"></a>
<a href="https://external.example/files/24">外部.pdf</a>
<a href="/courses/99/files/25">其他课程.pdf</a>
<!-- <a href="/files/26">备注中的链接.pdf</a> -->
''',
          },
          {
            'id': '8',
            'name': '不可见作业',
            'published': false,
            'description': '<a href="/files/27">附件.pdf</a>',
          },
        ],
        'agent.remoteFile.read' when params['file_id'] == '21' => _asset(
          '电路.png',
          'image/png',
          _png,
        ),
        'agent.remoteFile.read' when params['file_id'] == '23' => _asset(
          '原件.txt',
          'text/plain',
          utf8.encode('原始文本'),
        ),
        _ => throw StateError(method),
      },
    );

    Future<void> openAssignment() async {
      for (final label in ['eLearning', '芯片导论', '作业附件']) {
        await _tap(tester, label);
      }
      expect(find.text('不可见作业'), findsNothing);
      await _tap(tester, 'Assignment 1');
    }

    await fixture.open(tester);
    await openAssignment();
    for (final label in ['说明.pdf', '电路.png', '备注.txt', '作业文件 23']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in ['外部.pdf', '其他课程.pdf', '备注中的链接.pdf']) {
      expect(find.text(label), findsNothing);
    }
    expect(fixture.downloads, isEmpty);
    await _tap(tester, '电路.png');
    expect(fixture.downloads.single, {
      'source': 'canvas',
      'course_id': '42',
      'assignment_id': '7',
      'file_id': '21',
    });
    expect(base64Decode(fixture.result!.base64Data), _png);

    await _tap(tester, '打开选择器');
    await openAssignment();
    await _tap(tester, '作业文件 23');
    expect(fixture.downloads.last['file_id'], '23');
    expect(fixture.result?.name, '原件.txt');
    expect(fixture.result?.text, '原始文本');
  });

  testWidgets('browses personal and group directories and retries failures', (
    tester,
  ) async {
    var groupRequests = 0;
    var downloads = 0;
    final fixture = _Fixture(
      (method, params) => switch (method) {
        'fudan.cloud.roots' => _roots,
        'fudan.cloud.list' when params['path'] == 'personal:' => {'items': []},
        'fudan.cloud.list' when params['path'] == 'group:' =>
          ++groupRequests == 1
              ? throw PlatformException(code: 'NetworkError')
              : {
                  'items': [_item('共享目录', 'folder:', folder: true)],
                },
        'fudan.cloud.list' when params['path'] == 'folder:' => {
          'items': [_item('agenda.pdf', 'opaque file+%')],
        },
        'agent.remoteFile.read' =>
          ++downloads == 1
              ? throw PlatformException(code: 'AssetMissing')
              : _asset('agenda.pdf', 'application/pdf', _pdf),
        _ => throw StateError(method),
      },
    );
    await fixture.open(tester);
    await _tap(tester, '复旦云盘');
    await _tap(tester, '个人空间');
    expect(find.text('这里没有可选项目'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _tap(tester, '课题组');
    await _tap(tester, '重试');
    await _tap(tester, '共享目录');
    expect(fixture.downloads, isEmpty);
    await _tap(tester, 'agenda.pdf');
    expect(find.text('文件暂时无法读取，请重新查询。'), findsOneWidget);
    await _tap(tester, '重试下载');
    expect(fixture.downloads, [
      {'source': 'cloud', 'path': 'opaque file+%'},
      {'source': 'cloud', 'path': 'opaque file+%'},
    ]);
    expect(fixture.result?.isCampusFile, isTrue);
    expect(base64Decode(fixture.result!.base64Data), _pdf);
  });

  testWidgets('invalidates an in-flight download on account change', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    final fixture = _Fixture(
      (method, params) => switch (method) {
        'fudan.cloud.roots' => _roots,
        'fudan.cloud.list' => {
          'items': [_item('旧账号文件.pdf', 'file:')],
        },
        'agent.remoteFile.read' => pending.future,
        _ => throw StateError(method),
      },
    );
    await fixture.open(tester);
    await _tap(tester, '复旦云盘');
    await _tap(tester, '个人空间');
    await tester.tap(find.text('旧账号文件.pdf'));
    await tester.pump();
    expect(find.text('正在下载 旧账号文件.pdf…'), findsOneWidget);

    fixture.controller.select('different-account');
    fixture.controller.select('fixture-account');
    pending.complete(_asset('旧账号文件.pdf', 'application/pdf', _pdf));
    await tester.pumpAndSettle();
    expect(find.text('账号已变更，请返回后重新打开。'), findsOneWidget);
    expect(find.text('旧账号文件.pdf'), findsNothing);
    expect(fixture.finished, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fixture.finished, isTrue);
    expect(fixture.result, isNull);
  });
}

const _courses = [
  {'id': '42', 'name': '芯片导论'},
];
const _roots = [
  {'name': '个人空间', 'kind': 'personal', 'path': 'personal:'},
  {'name': '课题组', 'kind': 'group', 'path': 'group:'},
];

Json _item(String name, String path, {bool folder = false}) => {
  'name': name,
  'path': path,
  'is_folder': folder,
};

Json _asset(String name, String mime, List<int> bytes) => {
  'name': name,
  'mime_type': mime,
  'data': base64Encode(bytes),
};

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

class _Fixture implements DanshengBridge {
  _Fixture(this.respond) {
    addTearDown(() {
      api.accountScope!.dispose();
      controller.dispose();
    });
  }

  final FutureOr<Object?> Function(String, Json) respond;
  final downloads = <Json>[];
  late final controller = _Controller(this);
  late final api = CampusApi.forAccount(controller);
  AgentAttachment? result;
  bool finished = false;

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<AgentAttachment>(
                  MaterialPageRoute(
                    builder: (_) => AgentCloudAttachmentPicker(api: api),
                  ),
                );
                finished = true;
              },
              child: const Text('打开选择器'),
            ),
          ),
        ),
      ),
    );
    await _tap(tester, '打开选择器');
  }

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    expect(command, HostCommand.campus);
    final call = jsonDecode(payload) as Json;
    final method = call['method'] as String;
    final params = call['params'] as Json;
    expect(params.remove('account_id'), 'fixture-account');
    if (method == 'agent.remoteFile.read') downloads.add(params);
    return jsonEncode(await respond(method, params));
  }
}

class _Controller extends DanshengController {
  _Controller(DanshengBridge bridge)
    : super(client: DanshengClient(bridge: bridge));

  @override
  String activeAccountId = 'fixture-account';

  void select(String account) {
    activeAccountId = account;
    notifyListeners();
  }
}
