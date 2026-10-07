// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/src/isolate/midi_transport.dart';
import 'package:test/test.dart';

void main() {
  group('midi_transport', () {
    test('runs MIDI hosts in MIDI isolates on the Dart VM', () {
      expect(midiIsolatesSupported, isTrue);
    });
  });
}
