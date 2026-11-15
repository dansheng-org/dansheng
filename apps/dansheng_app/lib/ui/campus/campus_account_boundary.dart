import 'package:flutter/material.dart';

import 'campus_api.dart';

/// Withdraws an account-bound route, including dialogs wrapped separately,
/// as soon as its originating identity expires. Other routes stay in place.
class CampusAccountBoundary extends StatefulWidget {
  const CampusAccountBoundary({
    super.key,
    required this.api,
    required this.child,
  });
  final CampusApi api;
  final Widget child;

  @override
  State<CampusAccountBoundary> createState() => _CampusAccountBoundaryState();
}

class _CampusAccountBoundaryState extends State<CampusAccountBoundary> {
  late final CampusApi _api = widget.api;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _api.accountScope?.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _changed();
  }

  void _changed() {
    if (_api.isCurrent || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isFirst) {
        route.navigator?.removeRoute(route);
      } else {
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _api.accountScope?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _api.isCurrent
      ? widget.child
      : const Scaffold(body: Center(child: Text('账号已变更，请返回后重新打开')));
}
