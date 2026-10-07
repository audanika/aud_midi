// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'midi_host_command.dart';
import 'midi_host_notice.dart';

// #############################################################################
/// The connection of a proxy to its MIDI host.
///
/// A link to a host in another isolate sends commands through the host's
/// `SendPort` and receives notices on a `ReceivePort`; a link to a host in
/// the same isolate passes both on directly. Either way, commands and
/// notices keep their order and arrive asynchronously.
abstract interface class MidiLink {
  // ...........................................................................
  /// Sends [command] to the host.
  ///
  /// Throws when [command] cannot reach the host, e.g. an
  /// [ArgumentError] when it holds something an isolate cannot receive.
  void send(MidiHostCommand command);

  /// Asks the host to forget the proxy [proxy] when the isolate of the
  /// proxy ends without closing it.
  void watch({required int proxy});

  /// Closes the link; no notice arrives afterwards.
  void close();

  // ...........................................................................
  /// The sink the host posts the notices of the proxy to; the proxy sends
  /// it along in its `MidiHelloCommand`.
  MidiNoticeSink get sink;
}
