// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

void main() {
  group('midi_family', () {
    test('re-exports aud_midi_standard', () {
      expect(
        const MidiNoteOn(channel: 0, note: 60, velocity: 100).toBytes(),
        MidiBytes([0x90, 60, 100]),
      );
    });

    test('re-exports aud_midi_core', () {
      expect(FakeMidiBackend().name, 'fake');
      expect(const MidiPortGone(MidiPortId('fake:x')), isA<MidiException>());
    });
  });
}
