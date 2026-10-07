// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi.dart';

// #############################################################################
/// The handle on an output port, which carries MIDI out of the app.
///
/// The first call opens the port in the MIDI isolate; [close] closes it.
/// Every send goes to the MIDI isolate at once: a future [send] time is
/// kept there or in the operating system, so a busy app isolate cannot
/// delay it. The returned futures complete when the port accepted the
/// messages, not when they left the device; they fail with the errors of
/// the MIDI isolate, e.g. a `MidiPortGone` after the port disappeared.
///
/// Messages are translated to what the port takes: MIDI 1.0 bytes, or
/// Universal MIDI Packets in the protocol of the port. Messages without an
/// equivalent there are dropped and reported as
/// `MidiDiagnosticKind.untranslatable`.
final class MidiOutput {
  MidiOutput._(this._midi, this._info);

  // ...........................................................................
  /// Sends [message] at [at] on [group].
  ///
  /// - [at] the due time on the package clock (`Midi.now`); null or a past
  ///   time sends at once.
  /// - [group] the group of a UMP port, 0 to 15; null for the port's
  ///   group. Byte ports ignore it.
  Future<void> send(MidiMessage message, {MidiTime? at, int? group}) =>
      sendAll([message], at: at, group: group);

  /// Sends [messages] together, in one packet, at [at] on [group], like
  /// [send].
  Future<void> sendAll(
    Iterable<MidiMessage> messages, {
    MidiTime? at,
    int? group,
  }) => _midi._call<void>(
    (request) => MidiSendCommand(
      proxy: _midi._id,
      request: request,
      port: id,
      messages: List.unmodifiable(messages),
      at: at,
      group: group,
    ),
  );

  /// Sends the MIDI 1.0 byte stream [bytes] at [at]; they must hold
  /// complete messages, System Exclusive included.
  Future<void> sendBytes(List<int> bytes, {MidiTime? at}) => _sendPacket(
    MidiBytesPacket(bytes: MidiBytes(bytes), time: at ?? _midi.now()),
  );

  /// Sends the Universal MIDI Packets [words] at [at]; they must form
  /// complete packets.
  Future<void> sendUmp(List<int> words, {MidiTime? at}) =>
      _sendPacket(MidiUmpPacket(words: words, time: at ?? _midi.now()));

  // ...........................................................................
  /// Discards the messages of the port that wait for their due time, in
  /// the MIDI isolate and, where the port supports it, in the operating
  /// system; this affects the messages of every isolate.
  ///
  /// Returns the number of packets that still leave: those an operating
  /// system holds that cannot discard them.
  Future<int> cancelPending() => _midi._call<int>(
    (request) =>
        MidiCancelPendingCommand(proxy: _midi._id, request: request, port: id),
  );

  /// Silences the port as [panic] describes: discards what is pending
  /// when told to, then sends Note Off for the notes still on, All Sound
  /// Off, Reset All Controllers and All Notes Off.
  Future<void> panic({MidiPanic panic = const MidiPanic()}) =>
      _midi._call<void>(
        (request) => MidiOutputPanicCommand(
          proxy: _midi._id,
          request: request,
          port: id,
          panic: panic,
        ),
      );

  /// Closes the port in this isolate; the messages it still has pending
  /// are discarded when no other isolate uses the port. A later send opens
  /// the port again. Does nothing once the proxy is closed.
  Future<void> close() async {
    if (_midi._closing != null || _midi._isClosed) return;
    await _midi._call<void>(
      (request) =>
          MidiCloseOutputCommand(proxy: _midi._id, request: request, port: id),
    );
  }

  // ...........................................................................
  /// The description of the port; the last one known after the port
  /// disappeared.
  MidiPortInfo get info => _info;

  /// The id of the port.
  MidiPortId get id => _info.id;

  // ...........................................................................
  final Midi _midi;
  MidiPortInfo _info;

  /// Sends the raw [packet] at its time.
  Future<void> _sendPacket(MidiPacket packet) => _midi._call<void>(
    (request) => MidiSendPacketCommand(
      proxy: _midi._id,
      request: request,
      port: id,
      packet: packet,
    ),
  );
}
