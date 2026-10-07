// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/backend/midi_browse_lock_network.dart';
import 'package:aud_midi/src/backend/midi_lazy_service_advertiser.dart';
import 'package:aud_midi/src/backend/midi_platform_backend_io.dart';
import 'package:aud_midi_android/aud_midi_android.dart';
import 'package:aud_midi_apple/aud_midi_apple.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_windows/aud_midi_windows.dart';
import 'package:test/test.dart';

void main() {
  // Returns the composition of [os] with the network session it ends with.
  ({MidiCompositeBackend backend, MidiNetworkSessionBackend session}) composed(
    String os, {
    MidiOptions options = const MidiOptions(),
  }) {
    final backend =
        midiPlatformBackend(options, os: os) as MidiCompositeBackend;
    return (
      backend: backend,
      session: backend.optionalBackends.last as MidiNetworkSessionBackend,
    );
  }

  group('midiPlatformBackend(options, os)', () {
    test('runs CoreMIDI with its own session on iOS', () {
      final backend = midiPlatformBackend(
        const MidiOptions(clientName: 'app'),
        os: 'ios',
      );
      expect(backend, isA<AppleMidiBackend>());
      expect((backend as AppleMidiBackend).clientName, 'app');
    });

    test('adds a Network MIDI 2.0 session on iOS on request', () {
      final (:backend, :session) = composed(
        'ios',
        options: const MidiOptions(
          networkProtocol: MidiNetworkProtocol.networkMidi2,
        ),
      );
      expect(backend.name, 'apple');
      expect(backend.backends.single, isA<AppleMidiBackend>());
      expect(session.protocol, MidiNetworkProtocol.networkMidi2);
      expect(session.name, 'netmidi2');
      expect(backend.network, same(session));
    });

    test('adds an AppleMIDI session announced by Bonjour on macOS', () {
      final (:backend, :session) = composed(
        'macos',
        options: const MidiOptions(clientName: 'app'),
      );
      expect(backend.name, 'apple');
      expect((backend.backends.single as AppleMidiBackend).clientName, 'app');
      expect(backend.optionalBackends, [session]);
      expect(session.protocol, MidiNetworkProtocol.appleMidi);
      expect(session.name, 'netmidi');
      expect(session.advertiser, isA<MidiBonjourAdvertiser>());
      expect(backend.network, same(session));
    });

    test('adds a session with NsdManager and a multicast lock on Android', () {
      final (:backend, :session) = composed('android');
      expect(backend.name, 'android');
      expect(backend.backends.single, isA<AndroidMidiBackend>());
      final advertiser = session.advertiser! as MidiLazyServiceAdvertiser;
      expect(advertiser.isCreated, isFalse);
      expect(
        advertiser.create,
        throwsA(isA<MidiUnsupported>()),
        reason: 'NsdManager exists on Android only',
      );
      final network = backend.network! as MidiBrowseLockNetwork;
      expect(network.network, same(session));
      expect(network.acquire, throwsA(isA<MidiUnsupported>()));
      network.release();
    });

    test('adds a session with DnsServiceRegister on Windows', () {
      final (:backend, :session) = composed('windows');
      expect(backend.name, 'windows');
      expect(backend.backends.single, isA<WindowsMidiBackend>());
      expect(session.advertiser, isA<MidiLazyServiceAdvertiser>());
      expect(backend.network, same(session));
    });

    test('adds Bluetooth over BlueZ and a session with Avahi on Linux', () {
      final (:backend, :session) = composed(
        'linux',
        options: const MidiOptions(clientName: 'app'),
      );
      expect(backend.name, 'linux');
      final alsa = backend.backends.single as LinuxMidiBackend;
      expect(alsa.clientName, 'app');
      expect(alsa.bluetooth, isNull);
      expect(backend.optionalBackends.first, isA<MidiBleBluetoothBackend>());
      expect(
        (backend.optionalBackends.first as MidiBleBluetoothBackend).transport,
        isA<MidiBlueZBleTransport>(),
      );
      expect(session.advertiser, isA<MidiAvahiServiceAdvertiser>());
    });

    test('selects the backend of the running system by default', () {
      expect(midiPlatformBackend(const MidiOptions()), isA<MidiBackend>());
    });

    test('throws for other systems', () {
      expect(
        () => midiPlatformBackend(const MidiOptions(), os: 'fuchsia'),
        throwsA(
          isA<MidiUnsupported>().having(
            (e) => e.feature,
            'feature',
            'MIDI on fuchsia',
          ),
        ),
      );
    });
  });
}
