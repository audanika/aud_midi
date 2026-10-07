// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// The remote network session refused the connection or did not answer.
///
/// `MidiNetwork.connect` throws it instead of returning a connection in the
/// state [MidiNetworkConnectionState.failed].
final class MidiNetworkConnectionFailed implements Exception {
  /// Creates the error for the failed [connection].
  const MidiNetworkConnectionFailed(this.connection);

  // ...........................................................................
  /// The connection in the state [MidiNetworkConnectionState.failed].
  final MidiNetworkConnectionInfo connection;

  // ...........................................................................
  @override
  String toString() {
    final host = connection.host;
    return 'MidiNetworkConnectionFailed: ${host.name} at '
        '${host.address}:${host.port} did not accept the connection';
  }
}
