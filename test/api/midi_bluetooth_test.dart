// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

MidiBackend _backend() {
  final fake = FakeMidiBackend();
  fake.bluetooth!.addPeripheral(MidiBlePeripheralInfo(id: 'p1', name: 'Keys'));
  return fake;
}

Future<List<String>> _peripheralStates(Midi midi) => midi.withBackend(
  (backend) => [
    for (final peripheral
        in (backend as FakeMidiBackend).bluetooth!.peripherals)
      peripheral.state.name,
  ],
);

void main() {
  late Midi midi;

  for (final inIsolate in [false, true]) {
    final mode = inIsolate ? 'in-isolate' : 'MIDI isolate';

    group('MidiBluetooth ($mode)', () {
      setUp(() async {
        midi = await Midi.open(
          options: MidiOptions(backend: _backend, inIsolate: inIsolate),
        );
      });

      tearDown(() async => midi.close());

      group('scan(timeout), stopScan()', () {
        test('report peripherals until the scan stops', () async {
          final found = <MidiBlePeripheralInfo>[];
          final done = midi.bluetooth!
              .scan(timeout: const Duration(minutes: 1))
              .forEach(found.add);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await midi.bluetooth!.stopScan();
          await done;
          expect(found.map((peripheral) => peripheral.name), ['Keys']);
        });
      });

      group('connect(peripheralId), disconnect(peripheralId)', () {
        test('add and remove the ports of a peripheral', () async {
          final ports = await midi.bluetooth!.connect(
            'p1',
            timeout: const Duration(seconds: 1),
          );
          expect(ports.map((port) => port.direction), [
            MidiDirection.input,
            MidiDirection.output,
          ]);
          expect(midi.input(ports.first.id), isNotNull);
          expect(midi.output(ports.last.id), isNotNull);
          expect(await _peripheralStates(midi), ['connected']);
          await midi.bluetooth!.disconnect('p1');
          expect(await _peripheralStates(midi), ['disconnected']);
        });

        test('fail for an unknown peripheral', () async {
          await expectLater(
            midi.bluetooth!.connect('nobody'),
            throwsA(isA<MidiPortGone>()),
          );
        });
      });
    });
  }
}
