import '../../../core/dansheng_client.dart';
import '../../campus_api.dart';
import 'board_layout.dart';

/// Keeps the arrangement of the eHall home on this device.
///
/// The arrangement is an interface preference: it holds no campus data, is
/// shared by every account on the device and can be read before sign-in.
class BoardStore {
  BoardStore(DanshengClient client)
    : _client = client,
      _api = CampusApi(client);

  final DanshengClient _client;
  final CampusApi _api;

  // The page is rebuilt whenever the account changes; remembering the layout
  // per client keeps it from blinking through an empty state each time.
  static final _remembered = Expando<BoardLayout>();

  /// The layout if this client has already loaded or saved one.
  BoardLayout? get remembered => _remembered[_client];

  /// Reads the saved layout. A host that has none, or cannot answer, gives
  /// the standard layout; the board must always open.
  Future<BoardLayout> load() async {
    final known = remembered;
    if (known != null) return known;
    try {
      final layout = BoardLayout.fromJson(await _api.call('ehall.layout.get'));
      return _remembered[_client] ??= layout;
    } catch (_) {
      // Not remembered, so the next page tries the host again.
      return remembered ?? BoardLayout.standard();
    }
  }

  /// Saves [layout]. Throws when the host could not store it.
  ///
  /// Saves go out one after another: the host runs every call on its own
  /// thread, so overlapping saves could otherwise land out of order and
  /// leave an older arrangement on disk.
  Future<void> save(BoardLayout layout) {
    _remembered[_client] = layout;
    final previous = _saving[_client] ?? Future<void>.value();
    final next = previous
        .catchError((_) {})
        .then((_) => _api.call('ehall.layout.set', {'layout': layout.toJson()}))
        .then((_) {});
    _saving[_client] = next;
    return next;
  }

  static final _saving = Expando<Future<void>>();
}
