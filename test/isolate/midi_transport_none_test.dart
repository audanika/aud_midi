// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_transport_none.dart';
import 'package:test/test.dart';

void main() {
  group('midi_transport_none', () {
    test('has no MIDI isolates', () {
      expect(midiIsolatesSupported, isFalse);
      expect(
        () => midiSpawnHost(const MidiOptions()),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => midiRemoteLink(
          connector: const MidiConnector(host: 1),
          onNotice: (_) {},
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
