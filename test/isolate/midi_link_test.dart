// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host.dart';
import 'package:aud_midi/src/isolate/midi_link.dart';
import 'package:aud_midi/src/isolate/midi_local_link.dart';
import 'package:test/test.dart';

void main() {
  group('MidiLink', () {
    test('is implemented by the links of the transports', () {
      final MidiLink link = MidiLocalLink(
        host: MidiHost(backend: FakeMidiBackend()),
        onNotice: (_) {},
      );
      expect(link.sink, isA<Function>());
      link.close();
    });
  });
}
