// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

// .............................................................................
// The backend, created inside the MIDI isolate.

MidiBackend _backend() {
  final fake = FakeMidiBackend();
  final input = fake.addPort(
    fake.portInfo('in', direction: MidiDirection.input),
  );
  final output = fake.addPort(
    fake.portInfo('out', direction: MidiDirection.output),
  );
  fake.connectLoopback(output.id, input.id);
  return fake;
}

FakeMidiBackend _fake(MidiBackend backend) => backend as FakeMidiBackend;

// .............................................................................
// Actions that run inside the MIDI isolate.

/// Delivers [bytes] on [port] as received now; false while it is closed.
Future<bool> _inject(Midi midi, MidiPortId port, List<int> bytes) =>
    midi.withBackend(
      (backend) => _fake(backend).inject(
        port,
        MidiBytesPacket(
          bytes: MidiBytes(bytes),
          time: const MidiSystemClock().now(),
        ),
      ),
    );

Future<bool> _isOpen(Midi midi, MidiPortId port) =>
    midi.withBackend((backend) => _fake(backend).openPorts.contains(port));

Future<List<String>> _calls(Midi midi) =>
    midi.withBackend((backend) => _fake(backend).calls);

Future<void> _remove(Midi midi, MidiPortId port) =>
    midi.withBackend((backend) => _fake(backend).removePort(port));

Future<void> _failOpen(Midi midi) => midi.withBackend(
  (backend) => _fake(
    backend,
  ).failWith(openPort: const MidiNativeError(api: 'open', code: 3)),
);

void main() {
  late Midi midi;
  late MidiInput input;

  // Waits until the input port is [open] in the backend.
  Future<void> untilOpen({bool open = true}) async {
    while (await _isOpen(midi, input.id) != open) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  // Delivers [bytes] once the input is open.
  Future<void> inject(List<int> bytes) async {
    await untilOpen();
    expect(await _inject(midi, input.id, bytes), isTrue);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  for (final inIsolate in [false, true]) {
    final mode = inIsolate ? 'in-isolate' : 'MIDI isolate';

    group('MidiInput ($mode)', () {
      setUp(() async {
        midi = await Midi.open(
          options: MidiOptions(backend: _backend, inIsolate: inIsolate),
        );
        input = midi.inputs.single;
      });

      tearDown(() async {
        if (!midi.isClosed) await midi.close();
      });

      group('info, id', () {
        test('describe the port', () {
          expect(input.info.name, 'in');
          expect(input.id, input.info.id);
        });
      });

      group('messages', () {
        test('delivers the messages of the port with their time', () async {
          final events = <MidiEvent>[];
          final subscription = input.messages.listen(events.add);
          final sent = midi.now();
          await inject([0x90, 60, 100, 0x80, 60, 0]);
          await settle();
          expect(events.map((event) => event.message), [
            const MidiNoteOn(channel: 0, note: 60, velocity: 100),
            const MidiNoteOff(channel: 0, note: 60, velocity: 0),
          ]);
          expect(events.first.port, input.id);
          expect(events.first.time.isBefore(sent), isFalse);
          await subscription.cancel();
        });

        test('round-trips sends through the MIDI isolate', () async {
          final events = <MidiEvent>[];
          final subscription = input.messages.listen(events.add);
          await untilOpen();
          final due = midi.now() + const Duration(milliseconds: 30);
          await midi.outputs.single.send(
            const MidiControlChange(channel: 2, controller: 7, value: 99),
            at: due,
          );
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(
            events.single.message,
            const MidiControlChange(channel: 2, controller: 7, value: 99),
          );
          expect(events.single.time.isBefore(due), isFalse);
          await subscription.cancel();
        });

        test('shares one open port between listeners', () async {
          final first = <MidiEvent>[];
          final second = <MidiEvent>[];
          final a = input.messages.listen(first.add);
          final b = input.messages.listen(second.add);
          await inject([0xF8]);
          await settle();
          expect(first.single.message, const MidiTimingClock());
          expect(second.single.message, const MidiTimingClock());
          await a.cancel();
          expect(await _isOpen(midi, input.id), isTrue);
          await b.cancel();
          await untilOpen(open: false);
          expect(
            (await _calls(
              midi,
            )).where((call) => call == 'openPort ${input.id}'),
            hasLength(1),
          );
          final again = input.messages.listen((_) {});
          await untilOpen();
          await again.cancel();
        });

        test('keeps values for paused listeners up to the capacity', () async {
          final diagnostics = <MidiDiagnostic>[];
          final watching = midi.diagnostics.listen(diagnostics.add);
          final events = <MidiEvent>[];
          final subscription = input
              .messagesWith(const MidiInputOptions(queueCapacity: 2))
              .listen(events.add);
          subscription.pause();
          for (final status in [0xF8, 0xFA, 0xFB, 0xFC]) {
            await inject([status]);
          }
          await settle();
          expect(events, isEmpty);
          subscription.resume();
          await settle();
          expect(events.map((event) => event.message), [
            const MidiTimingClock(),
            const MidiStart(),
          ]);
          expect(diagnostics.map((diagnostic) => diagnostic.kind).toSet(), {
            MidiDiagnosticKind.queueOverflow,
          });
          expect(
            diagnostics.fold<int>(
              0,
              (sum, diagnostic) => sum + diagnostic.count,
            ),
            2,
          );
          expect(diagnostics.first.port, input.id);
          expect(
            diagnostics.first.cause,
            'Paused listeners of ${input.id} dropped 1 events beyond their '
            'capacity of 2',
          );
          await subscription.cancel();
          await watching.cancel();
        });

        test('stops delivering to a listener that cancelled', () async {
          final first = input.messages.first;
          await inject([0xF8, 0xFA]);
          expect((await first).message, const MidiTimingClock());
        });

        test('completes after the queued values when the port goes', () async {
          final events = <MidiEvent>[];
          final done = Completer<void>();
          final subscription = input.messages.listen(
            events.add,
            onDone: done.complete,
          );
          subscription.pause();
          await inject([0xF8, 0xFA]);
          await settle();
          await _remove(midi, input.id);
          await settle();
          subscription.resume();
          await done.future;
          expect(events.map((event) => event.message), [
            const MidiTimingClock(),
            const MidiStart(),
          ]);
          expect(input.info.name, 'in');
          expect(await input.messages.isEmpty, isTrue);
        });

        test('ends quietly when the port is gone before it opens', () async {
          final diagnostics = <MidiDiagnostic>[];
          final watching = midi.diagnostics.listen(diagnostics.add);
          await _remove(midi, input.id);
          expect(await input.messages.toList(), isEmpty);
          await settle();
          expect(diagnostics, isEmpty);
          await watching.cancel();
        });

        test('reports a port that fails to open', () async {
          final diagnostics = <MidiDiagnostic>[];
          final watching = midi.diagnostics.listen(diagnostics.add);
          await _failOpen(midi);
          expect(await input.messages.toList(), isEmpty);
          await settle();
          expect(diagnostics.single.kind, MidiDiagnosticKind.nativeError);
          expect(
            diagnostics.single.cause,
            'Opening the input failed: MidiNativeError: open failed with 3',
          );
          final cancelled = input.messages.listen((_) {});
          await cancelled.cancel();
          await settle();
          expect(diagnostics, hasLength(1));
          await watching.cancel();
        });

        test('ends at once on a closed proxy', () async {
          await midi.close();
          expect(await input.messages.isEmpty, isTrue);
        });
      });

      group('packets', () {
        test('delivers the raw packets of the port', () async {
          final packets = <MidiPacket>[];
          final subscription = input.packets.listen(packets.add);
          await inject([0x90, 1, 2]);
          await settle();
          expect(
            (packets.single as MidiBytesPacket).bytes,
            MidiBytes([0x90, 1, 2]),
          );
          await subscription.cancel();
        });
      });

      group('messagesWith(options)', () {
        test('decodes with the given options', () async {
          final events = <MidiEvent>[];
          final subscription = input
              .messagesWith(
                const MidiInputOptions(deliverAs: MidiProtocol.midi2),
              )
              .listen(events.add);
          await inject([0x90, 60, 127]);
          await settle();
          expect(events.single.message, isA<MidiNoteOn2>());
          await subscription.cancel();
        });
      });

      group('close()', () {
        test('ends every stream of the port in this isolate', () async {
          final done = <String>[];
          input.messages.listen((_) {}, onDone: () => done.add('messages'));
          input.packets.listen((_) {}, onDone: () => done.add('packets'));
          input
              .messagesWith(const MidiInputOptions())
              .listen((_) {}, onDone: () => done.add('with'));
          await untilOpen();
          await input.close();
          await settle();
          expect(done..sort(), ['messages', 'packets', 'with']);
          await untilOpen(open: false);
          await input.close();
        });
      });
    });
  }
}
