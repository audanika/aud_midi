// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// Creates the backend of a MIDI host inside the MIDI isolate.
///
/// The factory travels to the MIDI isolate, so it must be sendable: a
/// top-level or static function, or a closure that captures sendable values
/// only.
typedef MidiBackendFactory = MidiBackend Function();

// #############################################################################
/// The settings of the MIDI host that `Midi.open` starts.
///
/// Only the first `Midi.open` of a host uses them; proxies that join an
/// existing host share its settings.
final class MidiOptions {
  /// Creates options.
  ///
  /// - [backend] creates the backend inside the MIDI isolate; null selects
  ///   the backend of the platform: CoreMIDI on macOS and iOS,
  ///   `android.media.midi` on Android, Windows MIDI on Windows, the ALSA
  ///   sequencer on Linux, Web MIDI in the browser. Tests pass a function
  ///   that returns a `FakeMidiBackend`.
  /// - [engine] the settings of the engine: input defaults, the late
  ///   threshold of the software scheduler, translation options and the
  ///   lookahead; null for the defaults of the host, see [engineFor].
  /// - [inIsolate] runs the engine in the calling isolate instead of a MIDI
  ///   isolate of its own. The browser always does, because Web MIDI exists
  ///   on the main thread only. Other isolates cannot attach to such a
  ///   host.
  /// - [clientName] the name other applications see for this app, e.g. the
  ///   CoreMIDI or ALSA client name.
  /// - [sysEx] whether the browser asks for System Exclusive access too, a
  ///   stronger permission; other platforms always allow System Exclusive.
  /// - [networkProtocol] the protocol of the network session of the
  ///   platform backend: AppleMIDI (RTP-MIDI) by default, the operating
  ///   system's session on iOS; Network MIDI 2.0 runs the session of
  ///   `aud_midi_network` everywhere.
  const MidiOptions({
    this.backend,
    this.engine,
    this.inIsolate = false,
    this.clientName = 'aud_midi',
    this.sysEx = false,
    this.networkProtocol = MidiNetworkProtocol.appleMidi,
  });

  // ...........................................................................
  /// Returns a copy with the given fields replaced.
  ///
  /// - [clearBackend] sets [backend] to null; it wins over a given factory.
  /// - [clearEngine] sets [engine] to null; it wins over given settings.
  MidiOptions copyWith({
    MidiBackendFactory? backend,
    bool clearBackend = false,
    MidiEngineOptions? engine,
    bool clearEngine = false,
    bool? inIsolate,
    String? clientName,
    bool? sysEx,
    MidiNetworkProtocol? networkProtocol,
  }) => MidiOptions(
    backend: clearBackend ? null : backend ?? this.backend,
    engine: clearEngine ? null : engine ?? this.engine,
    inIsolate: inIsolate ?? this.inIsolate,
    clientName: clientName ?? this.clientName,
    sysEx: sysEx ?? this.sysEx,
    networkProtocol: networkProtocol ?? this.networkProtocol,
  );

  /// Returns the settings of the engine of a host: [engine], or the
  /// defaults for a host that runs in a MIDI isolate of its own
  /// ([inMidiIsolate]) or in the isolate of the app.
  ///
  /// A MIDI isolate is never blocked by the app, so its default keeps
  /// packets for ports that schedule but cannot discard, e.g. CoreMIDI
  /// virtual destinations, cancellable until [defaultLookahead] before
  /// they are due, then hands them to the operating system with their
  /// time. An engine in the isolate of the app, e.g. in a browser tab that
  /// may be throttled, hands them over at once instead: precise even when
  /// the isolate is busy, but no longer cancellable.
  MidiEngineOptions engineFor({required bool inMidiIsolate}) =>
      engine ??
      (inMidiIsolate
          ? const MidiEngineOptions(lookahead: defaultLookahead)
          : const MidiEngineOptions());

  // ...........................................................................
  /// Creates the backend inside the MIDI isolate, or null for the backend
  /// of the platform.
  final MidiBackendFactory? backend;

  /// The settings of the engine, or null for the defaults of the host.
  final MidiEngineOptions? engine;

  /// Whether the engine runs in the calling isolate.
  final bool inIsolate;

  /// The name other applications see for this app.
  final String clientName;

  /// Whether the browser asks for System Exclusive access too.
  final bool sysEx;

  /// The protocol of the network session of the platform backend.
  final MidiNetworkProtocol networkProtocol;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiOptions &&
          other.backend == backend &&
          other.engine == engine &&
          other.inIsolate == inIsolate &&
          other.clientName == clientName &&
          other.sysEx == sysEx &&
          other.networkProtocol == networkProtocol;

  @override
  int get hashCode => Object.hash(
    backend,
    engine,
    inIsolate,
    clientName,
    sysEx,
    networkProtocol,
  );

  @override
  String toString() =>
      'MidiOptions(backend: ${backend == null ? 'platform' : 'custom'}, '
      'engine: $engine, inIsolate: $inIsolate, '
      "clientName: '$clientName', sysEx: $sysEx, "
      'networkProtocol: ${networkProtocol.name})';

  // ...........................................................................
  /// The lookahead of an engine in a MIDI isolate, see [engineFor].
  static const Duration defaultLookahead = Duration(milliseconds: 100);
}
