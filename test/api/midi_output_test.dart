// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

// .............................................................................
// The backend, created inside the MIDI isolate.

MidiBackend _backend() {
  final fake = FakeMidiBackend();
  fake.addPort(fake.portInfo('out', direction: MidiDirection.output));
  fake.addPort(
    fake.portInfo(
      'ump',
      direction: MidiDirection.output,
      protocol: MidiProtocol.midi2,
      capabilities: const MidiPortCapabilities(ump: true),
    ),
  );
  return fake;
}

FakeMidiBackend _fake(MidiBackend backend) => backend as FakeMidiBackend;

// .............................................................................
// Actions that run inside the MIDI isolate.

/// Returns what the backend sent: the raw words or bytes and the delay
/// between the due time and the time the backend got the packet.
Future<List<(List<int>, int)>> _sent(Midi midi) => midi.withBackend(
  (backend) => [
    for (final sent in _fake(backend).sent)
      (
        switch (sent.packet) {
          MidiBytesPacket(:final bytes) => [...bytes.bytes],
          MidiUmpPacket(:final words) => [...words],
        },
        sent.sentAt.difference(sent.packet.time).inMicroseconds,
      ),
  ],
);

Future<bool> _isOpen(Midi midi, MidiPortId port) =>
    midi.withBackend((backend) => _fake(backend).openPorts.contains(port));

Future<void> _remove(Midi midi, MidiPortId port) =>
    midi.withBackend((backend) => _fake(backend).removePort(port));

void main() {
  late Midi midi;
  late MidiOutput output;
  late MidiOutput ump;

  Future<List<List<int>>> sentData() async => [
    for (final (data, _) in await _sent(midi)) data,
  ];

  for (final inIsolate in [false, true]) {
    final mode = inIsolate ? 'in-isolate' : 'MIDI isolate';

    group('MidiOutput ($mode)', () {
      setUp(() async {
        midi = await Midi.open(
          options: MidiOptions(backend: _backend, inIsolate: inIsolate),
        );
        output = midi.outputs.firstWhere((port) => port.info.name == 'out');
        ump = midi.outputs.firstWhere((port) => port.info.name == 'ump');
      });

      tearDown(() async {
        if (!midi.isClosed) await midi.close();
      });

      group('info, id', () {
        test('describe the port', () {
          expect(output.info.name, 'out');
          expect(output.id, output.info.id);
        });
      });

      group('send(message), sendAll(messages)', () {
        test('send at once in the order of the calls', () async {
          await output.send(
            const MidiNoteOn(channel: 0, note: 60, velocity: 100),
          );
          await output.sendAll([
            const MidiNoteOff(channel: 0, note: 60),
            const MidiProgramChange(channel: 1, program: 5),
          ]);
          expect(await sentData(), [
            [0x90, 60, 100],
            [0x80, 60, 64, 0xC1, 5],
          ]);
        });

        test('send at the due time', () async {
          final due = midi.now() + const Duration(milliseconds: 40);
          await output.send(const MidiStart(), at: due);
          expect(await sentData(), isEmpty);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          final [(data, delay)] = await _sent(midi);
          expect(data, [0xFA]);
          expect(delay, inInclusiveRange(0, 20000));
        });

        test('send MIDI 2.0 on the group of a UMP port', () async {
          await ump.send(
            const MidiNoteOn(channel: 0, note: 60, velocity: 127),
            group: 3,
          );
          final [data] = await sentData();
          expect(data.first >> 24, 0x43);
        });
      });

      group('sendBytes(bytes), sendUmp(words)', () {
        test('send raw data', () async {
          await output.sendBytes([0xB0, 7, 100]);
          await output.sendUmp([0x10F80000]);
          expect(await sentData(), [
            [0xB0, 7, 100],
            [0xF8],
          ]);
        });

        test('send raw data at the due time', () async {
          final due = midi.now() + const Duration(milliseconds: 30);
          await output.sendBytes([0xFA], at: due);
          await ump.sendUmp([0x10FA0000], at: due);
          expect(await sentData(), isEmpty);
          await Future<void>.delayed(const Duration(milliseconds: 70));
          expect(await sentData(), hasLength(2));
        });
      });

      group('cancelPending()', () {
        test('discards what waits for its time', () async {
          await output.send(
            const MidiStart(),
            at: midi.now() + const Duration(milliseconds: 30),
          );
          expect(await output.cancelPending(), 0);
          await Future<void>.delayed(const Duration(milliseconds: 60));
          expect(await sentData(), isEmpty);
        });
      });

      group('panic(panic)', () {
        test('silences the port', () async {
          await output.send(const MidiNoteOn(channel: 3, note: 1, velocity: 1));
          await output.panic(
            panic: const MidiPanic(
              channels: [3],
              allSoundOff: false,
              resetAllControllers: false,
              allNotesOff: false,
            ),
          );
          expect((await sentData()).last, [0x83, 1, 64]);
        });
      });

      group('close()', () {
        test('closes the port until the next send', () async {
          await output.send(const MidiStop());
          expect(await _isOpen(midi, output.id), isTrue);
          await output.close();
          expect(await _isOpen(midi, output.id), isFalse);
          await output.send(const MidiStop());
          expect(await _isOpen(midi, output.id), isTrue);
        });

        test('does nothing once the proxy is closed', () async {
          await midi.close();
          await output.close();
          await expectLater(
            output.send(const MidiStop()),
            throwsA(isA<StateError>()),
          );
        });
      });

      group('errors', () {
        test('come back as the exceptions of the MIDI isolate', () async {
          final id = output.id;
          await _remove(midi, id);
          await expectLater(
            output.send(const MidiStop()),
            throwsA(isA<MidiPortGone>().having((e) => e.port, 'port', id)),
          );
          expect(output.info.name, 'out');
        });
      });
    });
  }
}
