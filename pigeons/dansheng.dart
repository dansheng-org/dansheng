import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/bridge.g.dart',
  kotlinOut: 'android/app/src/main/kotlin/org/dansheng/app/Bridge.g.kt',
  kotlinOptions: KotlinOptions(package: 'org.dansheng.app'),
))
enum HostCommand {
  info, plugins, importPackage, enablePlugin, disablePlugin, removePlugin,
  component, preview, runAction, jobs, events, account, setAccount,
  permissions, openAlarmSettings, requestNotifications, balance, campus,
}

@HostApi()
abstract class DanshengApi {
  @async
  String invoke(HostCommand command, String payload);
}
