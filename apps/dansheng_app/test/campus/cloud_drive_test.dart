import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/cloud_drive_page.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/cloud_models.dart';
import 'package:dansheng_app/ui/campus/learning/cloud/drive_backend.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bridge implements DanshengBridge {
  final calls = <(String, Map)>[];
  bool signedIn = true;

  static const _roots = [
    {'kind': 'personal', 'name': '个人文件', 'path': '3/42/directory/'},
    {'kind': 'group', 'name': '课题组', 'path': '2/7/directory/'},
  ];

  Map<String, dynamic> _item(
    String name,
    String path, {
    bool folder = false,
    bool downloadable = true,
  }) => {
    'name': name,
    'path': path,
    'is_folder': folder,
    'size': folder ? null : 2048,
    'modified_at': '2026-11-10T08:00:00Z',
    'content_type': folder ? null : 'application/pdf',
    'children': folder ? 1 : null,
    'downloadable': !folder && downloadable,
  };

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    final request = jsonDecode(payload) as Map;
    final method = request['method'] as String;
    final params = request['params'] as Map;
    calls.add((method, params));
    if (method == 'campus.login') {
      signedIn = true;
      return '{}';
    }
    if (method == 'campus.cached') return 'null';
    if (!signedIn && method.startsWith('fudan.cloud.')) {
      throw PlatformException(code: 'AuthenticationRequired');
    }
    return jsonEncode(switch (method) {
      'fudan.cloud.roots' => _roots,
      'fudan.cloud.list' => {
        'path': params['path'],
        'items': switch (params['path']) {
          '3/42/directory/' => [
            _item('课件', '3/42/directory/课件', folder: true),
            _item('讲义.pdf', '3/42/directory/讲义.pdf'),
            _item('受限.pdf', '3/42/directory/受限.pdf', downloadable: false),
          ],
          '3/42/directory/课件' => [
            _item('第一讲.pdf', '3/42/directory/课件/第一讲.pdf'),
          ],
          '2/7/directory/' => [_item('组会.pptx', '2/7/directory/组会.pptx')],
          _ => [],
        },
      },
      'fudan.cloud.download' => {'asset_id': 'asset-1', 'name': '讲义.pdf'},
      'campus.openFile' => {'opened': true},
      'campus.saveFile' => {'saved': true, 'location': '下载（Download/旦生）'},
      _ => throw PlatformException(code: 'MethodUnavailable'),
    });
  }
}

Future<_Bridge> _pump(WidgetTester tester, {bool signedIn = true}) async {
  final bridge = _Bridge()..signedIn = signedIn;
  final api = CampusApi(DanshengClient(bridge: bridge));
  await tester.pumpWidget(
    MaterialApp(home: CloudDrivePage(drive: FudanCloudBackend(api))),
  );
  await tester.pumpAndSettle();
  return bridge;
}

void main() {
  testWidgets('browses folders, switches roots and goes back up', (
    tester,
  ) async {
    final bridge = await _pump(tester);
    expect(find.text('课件'), findsOneWidget);
    expect(find.text('讲义.pdf'), findsOneWidget);
    expect(find.text('2.0 KB · 11月10日 16:00'), findsNWidgets(2));

    await tester.tap(find.text('课件'));
    await tester.pumpAndSettle();
    expect(find.text('第一讲.pdf'), findsOneWidget);
    expect(bridge.calls.last.$2, {'path': '3/42/directory/课件'});

    // System back leaves the folder before it leaves the page.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('讲义.pdf'), findsOneWidget);
    expect(find.byType(CloudDrivePage), findsOneWidget);

    await tester.tap(find.text('课题组'));
    await tester.pumpAndSettle();
    expect(find.text('组会.pptx'), findsOneWidget);
  });

  testWidgets('downloads a file with its listing key, then opens it', (
    tester,
  ) async {
    final bridge = await _pump(tester);
    await tester.tap(find.text('讲义.pdf'));
    await tester.pumpAndSettle();
    final download = bridge.calls.firstWhere(
      (c) => c.$1 == 'fudan.cloud.download',
    );
    expect(download.$2, {
      'path': '3/42/directory/讲义.pdf',
      'size': 2048,
      'modified_at': '2026-11-10T08:00:00.000Z',
      'content_type': 'application/pdf',
    });
    expect(bridge.calls.last.$1, 'campus.openFile');
    expect(bridge.calls.last.$2, {'asset_id': 'asset-1'});

    // A file without the download right cannot be fetched.
    final before = bridge.calls.length;
    await tester.tap(find.text('受限.pdf'));
    await tester.pumpAndSettle();
    expect(bridge.calls.length, before);
  });

  testWidgets('saves a file to the phone from its menu', (tester) async {
    final bridge = await _pump(tester);
    await tester.longPress(find.text('讲义.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存到手机'));
    await tester.pumpAndSettle();
    expect(bridge.calls.last.$1, 'campus.saveFile');
    expect(bridge.calls.last.$2, {'asset_id': 'asset-1'});
    expect(find.text('已保存到下载（Download/旦生）'), findsOneWidget);
  });

  testWidgets('asks for the separate drive password, then loads', (
    tester,
  ) async {
    final bridge = await _pump(tester, signedIn: false);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('讲义.pdf'), findsNothing);
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(bridge.calls.firstWhere((c) => c.$1 == 'campus.login').$2, {
      'service': 'cloud',
    });
    expect(find.text('讲义.pdf'), findsOneWidget);
  });

  test('listing rows without a name or path are dropped', () {
    final items = cloudItemsOf({
      'items': [
        {'name': 'a.txt', 'path': '3/1/directory/a.txt', 'size': 10},
        {'name': '', 'path': '3/1/directory/x'},
        {'name': 'y'},
      ],
    });
    expect(items.single.sizeFormatted, '10 B');
    expect(cloudItemsOf(null), isEmpty);
  });
}
