// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// A network session that holds a lock while somebody browses, e.g. the
/// `WifiManager.MulticastLock` without which Android drops the multicast
/// DNS answers of other hosts.
///
/// Everything else goes to [network] unchanged.
final class MidiBrowseLockNetwork implements MidiNetworkBackend {
  /// Creates the session that wraps [network].
  ///
  /// - [acquire] takes the lock when the first browser starts; what it
  ///   throws reaches that browser as an error, and browsing goes on.
  /// - [release] gives the lock back when the last browser ends.
  MidiBrowseLockNetwork({
    required this.network,
    required this.acquire,
    required this.release,
  });

  // ...........................................................................
  @override
  Future<MidiNetworkSessionInfo> enable({
    required String name,
    int? port,
    MidiNetworkConnectionPolicy policy = MidiNetworkConnectionPolicy.anyone,
  }) => network.enable(name: name, port: port, policy: policy);

  @override
  Future<void> disable() => network.disable();

  // ...........................................................................
  @override
  Future<MidiNetworkConnectionInfo> connect(MidiNetworkHostInfo host) =>
      network.connect(host);

  @override
  Future<void> disconnect(MidiNetworkHostInfo host) => network.disconnect(host);

  // ...........................................................................
  /// Browses through [network] and holds the lock while at least one
  /// browser listens.
  @override
  Stream<List<MidiNetworkHostInfo>> browse() {
    late final StreamController<List<MidiNetworkHostInfo>> browser;
    StreamSubscription<List<MidiNetworkHostInfo>>? subscription;
    browser = StreamController(
      onListen: () {
        _lock(browser);
        subscription = network.browse().listen(
          browser.add,
          onError: browser.addError,
          onDone: browser.close,
        );
      },
      onCancel: () async {
        _unlock();
        await subscription?.cancel();
      },
    );
    return browser.stream;
  }

  // ...........................................................................
  /// The wrapped session.
  final MidiNetworkBackend network;

  /// Takes the lock.
  final void Function() acquire;

  /// Gives the lock back.
  final void Function() release;

  @override
  MidiNetworkSessionInfo get session => network.session;

  @override
  Stream<MidiNetworkSessionInfo> get sessionChanges => network.sessionChanges;

  /// The number of browsers that listen.
  int get browsers => _browsers;

  // ...........................................................................
  int _browsers = 0;

  /// Counts a browser and takes the lock for the first; a failure goes to
  /// [browser].
  void _lock(StreamController<List<MidiNetworkHostInfo>> browser) {
    if (_browsers++ > 0) return;
    try {
      acquire();
    } on Object catch (error, stack) {
      browser.addError(error, stack);
    }
  }

  /// Uncounts a browser and gives the lock back after the last.
  void _unlock() {
    if (--_browsers == 0) release();
  }
}
