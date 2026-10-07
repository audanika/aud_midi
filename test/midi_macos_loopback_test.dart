// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

// The thread independence check of the plan on real CoreMIDI: two MIDI
// hosts of this process, each with a CoreMIDI client of its own, see each
// other's virtual endpoints like two apps do. Host B runs for a worker
// isolate: it owns a virtual destination and a virtual source. Host A
// belongs to the test isolate, which schedules notes to B's destination,
// lets B send notes to A during the block, and blocks for 500 ms.
//
// Set AUD_MIDI_REPORT to a file path to write the measured numbers as JSON.

/// Runs host B: creates the endpoints named with [setup]'s suffix, records
/// the notes that arrive, sends notes when told and reports what arrived.
Future<void> _hostB((SendPort, String) setup) async {
  final (toTest, suffix) = setup;
  final commands = ReceivePort();
  final midi = await Midi.open(
    options: MidiOptions(clientName: 'aud_midi loop b $suffix'),
  );
  final destination = await midi.virtualPorts!.createDestination(
    'aud loop in $suffix',
  );
  final source = await midi.virtualPorts!.createSource('aud loop out $suffix');
  final received = <List<int>>[];
  final subscription = destination.messages.listen((event) {
    if (event.message case MidiNoteOn(:final note)) {
      received.add([
        note,
        event.time.microseconds,
        const MidiSystemClock().now().microseconds,
      ]);
    }
  });
  toTest.send(commands.sendPort);
  await for (final command in commands) {
    if (command case [final int start, final int count]) {
      for (var i = 0; i < count; i++) {
        unawaited(
          source.send(
            MidiNoteOn(channel: 1, note: i, velocity: 100),
            at: MidiTime(start) + Duration(milliseconds: 100 + 20 * i),
          ),
        );
      }
    } else {
      toTest.send(received);
      await subscription.cancel();
      await midi.close();
      commands.close();
    }
  }
}

/// Blocks the calling isolate for [duration] without yielding.
void _block(Duration duration) {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {}
}

Map<String, int> _stats(Iterable<int> values) {
  final sorted = [...values]..sort();
  int at(double p) => sorted[((sorted.length - 1) * p).round()];
  return {
    'count': sorted.length,
    'min': sorted.first,
    'median': at(0.5),
    'p95': at(0.95),
    'p99': at(0.99),
    'max': sorted.last,
  };
}

void main() {
  test(
    'a blocked app isolate delays neither CoreMIDI sends nor timestamps',
    () async {
      const count = 20;
      final suffix = '${Random().nextInt(1 << 30)}';
      final midi = await Midi.open(
        options: MidiOptions(clientName: 'aud_midi loop a $suffix'),
      );
      addTearDown(midi.close);
      final fromB = ReceivePort();
      final messages = StreamIterator(fromB);
      await Isolate.spawn(_hostB, (fromB.sendPort, suffix));
      expect(await messages.moveNext(), isTrue);
      final toB = messages.current! as SendPort;

      // Waits until host A lists the endpoints of host B.
      Future<T> portOf<T>(List<T> Function() handles, String name) async {
        for (var i = 0; i < 500; i++) {
          for (final handle in handles()) {
            final info = handle is MidiInput
                ? handle.info
                : (handle as MidiOutput).info;
            if (info.name == name) return handle;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        throw StateError('$name did not appear');
      }

      final toBInput = await portOf(() => midi.outputs, 'aud loop in $suffix');
      final fromBOutput = await portOf(
        () => midi.inputs,
        'aud loop out $suffix',
      );
      expect(toBInput.info.capabilities.scheduledSend, isTrue);

      final events = <MidiEvent>[];
      final received = <MidiTime>[];
      final subscription = fromBOutput.messages.listen((event) {
        events.add(event);
        received.add(midi.now());
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final start = midi.now();
      toB.send([start.microseconds, count]);
      for (var i = 0; i < count; i++) {
        unawaited(
          toBInput.send(
            MidiNoteOn(channel: 0, note: i, velocity: 100),
            at: start + Duration(milliseconds: 100 + 20 * i),
          ),
        );
      }
      _block(const Duration(milliseconds: 500));
      final unblocked = midi.now();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      toB.send('report');
      expect(await messages.moveNext(), isTrue);
      final atB = [
        for (final entry in messages.current! as List<Object?>)
          entry! as List<int>,
      ];
      await messages.cancel();
      await subscription.cancel();

      int due(int note) =>
          start.microseconds +
          (100 + 20 * note) * Duration.microsecondsPerMillisecond;

      // A's notes at B: CoreMIDI stamp and arrival in B's worker.
      final stampError = _stats([
        for (final [note, time, _] in atB) time - due(note),
      ]);
      final arrivalLateness = _stats([
        for (final [note, _, arrival] in atB) arrival - due(note),
      ]);
      // B's notes at A: stamp versus due time, and when A's isolate saw
      // them.
      final inputStampError = _stats([
        for (final event in events)
          event.time.microseconds - due((event.message as MidiNoteOn).note),
      ]);
      final report = {
        'blockMs': unblocked.difference(start).inMilliseconds,
        'sendsAtB_stampMinusDueUs': stampError,
        'sendsAtB_arrivalMinusDueUs': arrivalLateness,
        'inputsAtA_stampMinusDueUs': inputStampError,
        'inputsAtA_firstSeenAfterStartMs': received.first
            .difference(start)
            .inMilliseconds,
      };
      final path = Platform.environment['AUD_MIDI_REPORT'];
      if (path != null) {
        File(
          path,
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      }

      expect(atB, hasLength(count));
      expect(events, hasLength(count));
      // CoreMIDI's timestamps prove the timing; arrival times in the
      // worker isolates vary with machine load (e.g. pana during a
      // publish) and only have to stay far below the 500 ms block.
      expect(stampError['max']!.abs(), lessThan(5000), reason: '$report');
      expect(arrivalLateness['max'], lessThan(200000), reason: '$report');
      expect(inputStampError['max'], lessThan(200000), reason: '$report');
      expect(received.first.isBefore(unblocked), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
