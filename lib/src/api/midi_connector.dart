// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The sendable address of a MIDI host, the way for other isolates to join
/// it with `Midi.attach`.
///
/// Dart has no process-wide registry of isolates, so the isolate that
/// opened MIDI hands the connector of its proxy (`Midi.connector`) to its
/// workers, e.g. as the argument of `Isolate.spawn`. A connector is plain
/// data; it grants no control over the MIDI isolate beyond the MIDI API.
final class MidiConnector {
  /// Creates the connector of the host [host].
  ///
  /// Apps take connectors from `Midi.connector` instead of creating them.
  ///
  /// - [port] the `SendPort` the host receives commands on, null for a
  ///   host that runs in the isolate of its proxies.
  /// - [isolate] the MIDI isolate without control capabilities; proxies
  ///   watch it to notice when it ends.
  const MidiConnector({required this.host, this.port, this.isolate});

  // ...........................................................................
  /// The id of the host, unique within the process.
  final int host;

  /// The `SendPort` the host receives commands on, or null for a host that
  /// runs in the isolate of its proxies.
  final Object? port;

  /// The MIDI isolate, or null for a host that runs in the isolate of its
  /// proxies.
  final Object? isolate;

  /// Whether the host runs in the isolate of its proxies, so that other
  /// isolates cannot join it.
  bool get isLocal => port == null;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MidiConnector && other.host == host;

  @override
  int get hashCode => host.hashCode;

  @override
  String toString() =>
      'MidiConnector(host: $host, ${isLocal ? 'in-isolate' : 'isolate'})';
}
