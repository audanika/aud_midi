// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:isolate';

import '../api/midi_connector.dart';
import 'midi_host_command.dart';
import 'midi_host_notice.dart';
import 'midi_link.dart';

// #############################################################################
/// The link of a proxy to a host in a MIDI isolate, over ports.
///
/// Commands go to the `SendPort` of the host; notices arrive on a
/// `ReceivePort` of the link. The link watches the MIDI isolate and turns
/// its end into a [MidiHostExitNotice]; [watch] makes the host forget the
/// proxy when the proxy's isolate ends without closing it.
final class MidiPortLink implements MidiLink {
  /// Creates the link to the host of [connector] that delivers the notices
  /// to [onNotice].
  MidiPortLink({required MidiConnector connector, required this.onNotice})
    : _commands = connector.port! as SendPort {
    _notices.listen(_receive);
    final isolate = connector.isolate;
    if (isolate is Isolate) {
      isolate.addOnExitListener(_notices.sendPort, response: hostExit);
    }
  }

  // ...........................................................................
  @override
  void send(MidiHostCommand command) => _commands.send(command);

  /// Makes the isolate of the proxy send a goodbye of [proxy] to the host
  /// when it ends.
  @override
  void watch({required int proxy}) =>
      Isolate.current.addOnExitListener(_commands, response: [goodbye, proxy]);

  /// Stops watching and closes the port of the notices.
  @override
  void close() {
    Isolate.current.removeOnExitListener(_commands);
    _notices.close();
  }

  // ...........................................................................
  /// Receives the notices of the host.
  final MidiNoticeSink onNotice;

  /// Sends the notices to the port of the link.
  @override
  MidiNoticeSink get sink => _sinkOf(_notices.sendPort);

  // ...........................................................................
  /// The first element of the message the isolate of a proxy sends to the
  /// host when it ends; the id of the proxy follows.
  static const String goodbye = 'aud_midi:goodbye';

  /// The message the MIDI isolate sends to its proxies when it ends.
  static const String hostExit = 'aud_midi:host-exit';

  /// Returns the command a message on the command port of a host stands
  /// for: the message itself, or the goodbye of a proxy whose isolate
  /// ended.
  ///
  /// Throws an [ArgumentError] for anything else.
  static MidiHostCommand commandOf(Object? message) => switch (message) {
    final MidiHostCommand command => command,
    [goodbye, final int proxy] => MidiGoodbyeCommand(proxy: proxy, request: 0),
    _ => throw ArgumentError.value(message, 'message', 'No MIDI host command'),
  };

  // ...........................................................................
  final SendPort _commands;
  final _notices = ReceivePort('aud_midi notices');

  /// Passes [message] on as a notice; the only message that is none is the
  /// exit message of the MIDI isolate.
  void _receive(Object? message) => onNotice(
    message is MidiHostNotice ? message : const MidiHostExitNotice(),
  );

  /// Returns a sink that sends to [port]; created here, its closure holds
  /// nothing but the port, so it can travel to the host.
  static MidiNoticeSink _sinkOf(SendPort port) => port.send;
}
