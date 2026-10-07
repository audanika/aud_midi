// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_android/aud_midi_android.dart';
import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';

import '../api/midi_options.dart';
import 'midi_browse_lock_network.dart';
import 'midi_lazy_service_advertiser.dart';

// #############################################################################
/// Returns the backend of the operating system [os], by default the one the
/// code runs on; it runs in the MIDI isolate.
///
/// - macOS: CoreMIDI with its Bluetooth LE MIDI, plus the AppleMIDI session
///   of `aud_midi_network` announced through Bonjour, because
///   `MIDINetworkSession` does nothing on macOS.
/// - iOS: CoreMIDI with its Bluetooth LE MIDI and the network session of
///   the operating system; with [MidiNetworkProtocol.networkMidi2] the
///   session of `aud_midi_network` instead.
/// - Android: `android.media.midi` plus the session of `aud_midi_network`
///   announced through `NsdManager`; browsing holds a multicast lock.
/// - Windows: Windows MIDI plus the session of `aud_midi_network`
///   announced through `DnsServiceRegister`.
/// - Linux: the ALSA sequencer, Bluetooth LE MIDI over BlueZ and the
///   session of `aud_midi_network` announced through Avahi.
///
/// The network session and Bluetooth LE MIDI over BlueZ are optional parts:
/// when they fail to start, the rest runs and a diagnostic tells why.
///
/// Throws a [MidiUnsupported] for any other operating system.
MidiBackend midiPlatformBackend(MidiOptions options, {String? os}) {
  final system = os ?? Platform.operatingSystem;
  if (system == 'ios' &&
      options.networkProtocol == MidiNetworkProtocol.appleMidi) {
    return AppleMidiBackend(clientName: options.clientName);
  }
  return switch (system) {
    'macos' || 'ios' => _withSession(
      name: 'apple',
      main: [AppleMidiBackend(clientName: options.clientName)],
      options: options,
      advertiser: const MidiBonjourAdvertiser(),
    ),
    'android' => _withSession(
      name: 'android',
      main: [AndroidMidiBackend()],
      options: options,
      advertiser: MidiLazyServiceAdvertiser(MidiAndroidServiceAdvertiser.new),
      wrap: _multicastLocked,
    ),
    'windows' => _withSession(
      name: 'windows',
      main: [WindowsMidiBackend()],
      options: options,
      advertiser: MidiLazyServiceAdvertiser(WindowsMidiServiceAdvertiser.new),
    ),
    'linux' => _withSession(
      name: 'linux',
      main: [
        LinuxMidiBackend(clientName: options.clientName, bluetooth: false),
      ],
      options: options,
      advertiser: MidiAvahiServiceAdvertiser(),
      extra: [MidiBleBluetoothBackend(transport: MidiBlueZBleTransport())],
    ),
    _ => throw MidiUnsupported('MIDI on $system'),
  };
}

// #############################################################################
/// Returns [main] composed with the network session of `aud_midi_network`
/// in the protocol of [options], announced through [advertiser], and the
/// optional [extra] backends.
///
/// - [wrap] wraps the session for the network sub-API, e.g. to hold a lock
///   while browsing.
MidiCompositeBackend _withSession({
  required String name,
  required List<MidiBackend> main,
  required MidiOptions options,
  required MidiServiceAdvertiser advertiser,
  List<MidiBackend> extra = const [],
  MidiNetworkBackend Function(MidiNetworkBackend session)? wrap,
}) {
  final midi2 = options.networkProtocol == MidiNetworkProtocol.networkMidi2;
  final session = MidiNetworkSessionBackend(
    protocol: options.networkProtocol,
    name: midi2 ? 'netmidi2' : 'netmidi',
    advertiser: advertiser,
  );
  return MidiCompositeBackend(
    name: name,
    backends: main,
    optionalBackends: [...extra, session],
    network: wrap == null ? session : wrap(session),
  );
}

// #############################################################################
/// Returns [session] holding an Android multicast lock while browsing; the
/// lock is created at the first browse.
MidiNetworkBackend _multicastLocked(MidiNetworkBackend session) {
  MidiAndroidMulticastLock? lock;
  return MidiBrowseLockNetwork(
    network: session,
    acquire: () => (lock ??= MidiAndroidMulticastLock()).acquire(),
    release: () => lock?.release(),
  );
}
