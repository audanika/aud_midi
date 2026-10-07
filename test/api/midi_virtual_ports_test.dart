// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

MidiBackend _backend() => FakeMidiBackend();

Future<Map<String, Object?>> _native(Midi midi, MidiPortId port) => midi
    .withBackend((backend) => (backend as FakeMidiBackend).port(port)!.native);

Future<void> _forget(Midi midi, MidiPortId port) => midi.withBackend(
  (backend) => (backend as FakeMidiBackend).removePort(port),
);

void main() {
  late Midi midi;

  for (final inIsolate in [false, true]) {
    final mode = inIsolate ? 'in-isolate' : 'MIDI isolate';

    group('MidiVirtualPorts ($mode)', () {
      setUp(() async {
        midi = await Midi.open(
          options: MidiOptions(backend: _backend, inIsolate: inIsolate),
        );
      });

      tearDown(() async => midi.close());

      group('support', () {
        test('tells how the platform creates virtual ports', () {
          expect(
            midi.virtualPorts!.support,
            MidiVirtualPortSupport.dynamicPorts,
          );
        });
      });

      group('createSource(name), createDestination(name)', () {
        test('create own ports that other apps see', () async {
          final changes = <MidiPortEvent>[];
          final subscription = midi.changes.listen(changes.add);
          final source = await midi.virtualPorts!.createSource(
            'Out',
            uniqueId: 7,
            protocol: MidiProtocol.midi2,
            groups: [0, 1],
            manufacturer: 'Audanika',
            model: 'M',
          );
          final destination = await midi.virtualPorts!.createDestination(
            'In',
            uniqueId: 8,
            manufacturer: 'Audanika',
            model: 'N',
          );
          expect(source.info.isOwn, isTrue);
          expect(source.info.direction, MidiDirection.output);
          expect(source.info.protocol, MidiProtocol.midi2);
          expect(source.info.groups.map((group) => group.group), [0, 1]);
          expect(destination.info.direction, MidiDirection.input);
          expect(midi.output(source.id), same(source));
          expect(midi.input(destination.id), same(destination));
          expect(await _native(midi, source.id), {'uniqueId': 7, 'model': 'M'});
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(changes.map((event) => event.port.name), ['Out', 'In']);
          await subscription.cancel();
        });
      });

      group('remove(port)', () {
        test('removes an own port', () async {
          final source = await midi.virtualPorts!.createSource('Out');
          await midi.virtualPorts!.remove(source.id);
          expect(midi.output(source.id), isNull);
        });

        test('fails for a port it did not create', () async {
          final source = await midi.virtualPorts!.createSource('Out');
          await _forget(midi, source.id);
          await midi.virtualPorts!.remove(source.id);
          await expectLater(
            midi.virtualPorts!.remove(source.id),
            throwsA(isA<MidiPortGone>()),
          );
        });
      });
    });
  }
}
