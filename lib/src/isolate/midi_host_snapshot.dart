// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// The state of a MIDI host that a new proxy starts from: the answer to its
/// `MidiHelloCommand`.
///
/// Everything that changes afterwards reaches the proxy as notices, in the
/// order the host saw it.
final class MidiHostSnapshot {
  /// Creates a snapshot.
  ///
  /// - [proxy] the id the host gave the proxy.
  /// - [backend] the name of the backend, e.g. `coremidi`.
  /// - [session] the network session, null when the backend has none.
  const MidiHostSnapshot({
    required this.proxy,
    required this.backend,
    required this.capabilities,
    required this.ports,
    required this.hasVirtualPorts,
    required this.hasBluetooth,
    required this.session,
  });

  // ...........................................................................
  /// The id the host gave the proxy.
  final int proxy;

  /// The name of the backend.
  final String backend;

  /// What the backend supports.
  final MidiCapabilities capabilities;

  /// The known ports.
  final List<MidiPortInfo> ports;

  /// Whether the backend creates virtual ports.
  final bool hasVirtualPorts;

  /// Whether the backend connects Bluetooth LE MIDI peripherals.
  final bool hasBluetooth;

  /// The network session, or null when the backend has none.
  final MidiNetworkSessionInfo? session;
}
