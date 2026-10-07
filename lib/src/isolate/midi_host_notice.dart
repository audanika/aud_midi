// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// Receives the notices of a MIDI host for one proxy.
///
/// For a host in another isolate it is the `send` method of the proxy's
/// `SendPort`; for a host in the same isolate a function that queues the
/// notice.
typedef MidiNoticeSink = void Function(MidiHostNotice notice);

// #############################################################################
/// What a MIDI host tells one of its proxies: answers to commands and
/// everything that happens in the MIDI isolate.
///
/// The host posts the notices of a proxy in order; [MidiNoticeBatch]
/// combines the notices of one turn of the MIDI isolate's event loop into
/// one message.
sealed class MidiHostNotice {
  /// Creates a notice.
  const MidiHostNotice();
}

// #############################################################################
/// Several notices in their order.
final class MidiNoticeBatch extends MidiHostNotice {
  /// Creates a batch of [notices].
  const MidiNoticeBatch({required this.notices});

  // ...........................................................................
  /// The notices in their order.
  final List<MidiHostNotice> notices;
}

// #############################################################################
/// The successful answer to the command [request].
final class MidiReplyNotice extends MidiHostNotice {
  /// Creates the answer [value] to [request].
  const MidiReplyNotice({required this.request, this.value});

  // ...........................................................................
  /// The id of the answered command.
  final int request;

  /// The result of the command, null for none.
  final Object? value;
}

// #############################################################################
/// The failure of the command [request].
final class MidiFailureNotice extends MidiHostNotice {
  /// Creates the failure of [request] with [error] thrown at [stack].
  const MidiFailureNotice({
    required this.request,
    required this.error,
    required this.stack,
  });

  // ...........................................................................
  /// The id of the failed command.
  final int request;

  /// What the command threw, e.g. a `MidiException`.
  final Object error;

  /// The stack trace of [error] in the MIDI isolate, as text.
  final String stack;
}

// #############################################################################
/// Ports that appeared, disappeared or changed.
final class MidiPortsNotice extends MidiHostNotice {
  /// Creates the notice of [events].
  const MidiPortsNotice({required this.events});

  // ...........................................................................
  /// The port events in their order.
  final List<MidiPortEvent> events;
}

// #############################################################################
/// Losses and faults reported in the MIDI isolate.
final class MidiDiagnosticsNotice extends MidiHostNotice {
  /// Creates the notice of [diagnostics].
  const MidiDiagnosticsNotice({required this.diagnostics});

  // ...........................................................................
  /// The diagnostics in their order.
  final List<MidiDiagnostic> diagnostics;
}

// #############################################################################
/// New capabilities of the backend, e.g. after a permission was granted.
final class MidiCapabilitiesNotice extends MidiHostNotice {
  /// Creates the notice of [capabilities].
  const MidiCapabilitiesNotice({required this.capabilities});

  // ...........................................................................
  /// What the backend supports now.
  final MidiCapabilities capabilities;
}

// #############################################################################
/// A new state of the network session.
final class MidiSessionNotice extends MidiHostNotice {
  /// Creates the notice of [session].
  const MidiSessionNotice({required this.session});

  // ...........................................................................
  /// The state of the network session.
  final MidiNetworkSessionInfo session;
}

// #############################################################################
/// Values of the host stream [stream] of the proxy, e.g. the events of an
/// input or the peripherals of a Bluetooth scan.
final class MidiStreamNotice extends MidiHostNotice {
  /// Creates the notice of [values] for [stream].
  const MidiStreamNotice({required this.stream, required this.values});

  // ...........................................................................
  /// The id the proxy gave the stream.
  final int stream;

  /// The values in their order.
  final List<Object?> values;
}

// #############################################################################
/// An error of the host stream [stream] of the proxy, e.g. a Bluetooth scan
/// that failed; streams of MIDI data never carry errors.
final class MidiStreamErrorNotice extends MidiHostNotice {
  /// Creates the notice of [error] at [stack] for [stream].
  const MidiStreamErrorNotice({
    required this.stream,
    required this.error,
    required this.stack,
  });

  // ...........................................................................
  /// The id the proxy gave the stream.
  final int stream;

  /// The error of the stream.
  final Object error;

  /// The stack trace of [error] in the MIDI isolate, as text.
  final String stack;
}

// #############################################################################
/// The end of the host stream [stream] of the proxy, e.g. because the port
/// of an input disappeared.
final class MidiStreamDoneNotice extends MidiHostNotice {
  /// Creates the notice that [stream] ended.
  const MidiStreamDoneNotice({required this.stream});

  // ...........................................................................
  /// The id the proxy gave the stream.
  final int stream;
}

// #############################################################################
/// The MIDI isolate ended; a proxy that did not close yet learns it from
/// this notice, which its link creates when the isolate exits.
final class MidiHostExitNotice extends MidiHostNotice {
  /// Creates the notice.
  const MidiHostExitNotice();
}
