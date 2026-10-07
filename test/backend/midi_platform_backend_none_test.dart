// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/backend/midi_platform_backend_none.dart';
import 'package:test/test.dart';

void main() {
  group('midiPlatformBackend(options)', () {
    test('throws: no backend reaches MIDI here', () {
      expect(
        () => midiPlatformBackend(const MidiOptions()),
        throwsA(
          isA<MidiUnsupported>().having(
            (e) => e.feature,
            'feature',
            'MIDI on this platform',
          ),
        ),
      );
    });
  });
}
