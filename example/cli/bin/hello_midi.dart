// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// ignore_for_file: avoid_print

import 'package:aud_midi/aud_midi.dart';

Future<void> main() async {
  // Start the MIDI isolate with the backend of this platform
  final midi = await Midi.open();
  print('Backend: ${midi.backendName}');
  for (final input in midi.inputs) {
    print('Input:  ${input.info.name}');
  }
  for (final output in midi.outputs) {
    print('Output: ${output.info.name}');
  }

  // Create a virtual source that other apps can receive from
  final source = await midi.virtualPorts!.createSource('aud_midi hello');

  // Play C4 now and release it 500 ms later; the MIDI isolate schedules
  // the Note Off, so a busy app isolate cannot delay it
  await source.send(const MidiNoteOn(channel: 0, note: 60, velocity: 100));
  await source.send(
    const MidiNoteOff(channel: 0, note: 60),
    at: midi.now() + const Duration(milliseconds: 500),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  await midi.close();
}
