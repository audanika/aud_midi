// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
library;

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/backend/midi_platform_backend.dart';
import 'package:test/test.dart';

void main() {
  group('midi_platform_backend', () {
    test('selects the backend of the operating system on the Dart VM', () {
      expect(
        midiPlatformBackend(const MidiOptions()),
        isA<MidiCompositeBackend>().having((b) => b.name, 'name', 'apple'),
      );
    });
  });
}
