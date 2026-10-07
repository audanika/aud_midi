// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host_snapshot.dart';
import 'package:test/test.dart';

void main() {
  group('MidiHostSnapshot', () {
    group('MidiHostSnapshot()', () {
      test('keeps the state of the host', () {
        final port = MidiPortInfo(
          id: const MidiPortId('fake:in'),
          name: 'in',
          direction: MidiDirection.input,
        );
        final snapshot = MidiHostSnapshot(
          proxy: 2,
          backend: 'fake',
          capabilities: MidiCapabilities(ump: true),
          ports: [port],
          hasVirtualPorts: true,
          hasBluetooth: false,
          session: null,
        );
        expect(snapshot.proxy, 2);
        expect(snapshot.backend, 'fake');
        expect(snapshot.capabilities, MidiCapabilities(ump: true));
        expect(snapshot.ports, equals([port]));
        expect(snapshot.hasVirtualPorts, isTrue);
        expect(snapshot.hasBluetooth, isFalse);
        expect(snapshot.session, isNull);
      });
    });
  });
}
