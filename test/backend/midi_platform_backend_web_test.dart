// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/backend/midi_platform_backend_web.dart';
import 'package:aud_midi_web/aud_midi_web.dart';
import 'package:test/test.dart';

void main() {
  group('midiPlatformBackend(options)', () {
    test('returns Web MIDI with the System Exclusive request', () {
      for (final sysEx in [false, true]) {
        final backend = midiPlatformBackend(MidiOptions(sysEx: sysEx));
        expect(backend, isA<WebMidiBackend>());
        expect((backend as WebMidiBackend).sysEx, sysEx);
      }
    });
  });
}
