// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

// The thread independence check of the plan, with the fake backend in a
// real MIDI isolate: the app isolate schedules notes and then blocks for
// 500 ms in a busy loop. The notes have to leave on time, and messages
// that arrive during the block have to keep their receive time. All times
// come from MidiSystemClock, the process-wide clock both isolates read.
//
// Set AUD_MIDI_REPORT to a file path to write the measured numbers as JSON.

/// The software-scheduled output and the input of the test.
MidiBackend _backend() {
  final fake = FakeMidiBackend();
  fake
    ..addPort(fake.portInfo('out', direction: MidiDirection.output))
    ..addPort(fake.portInfo('in', direction: MidiDirection.input));
  return fake;
}

/// Returns the lateness in microseconds of every packet sent so far.
Future<List<int>> _lateness(Midi midi) => midi.withBackend(
  (backend) => [
    for (final sent in (backend as FakeMidiBackend).sent)
      sent.sentAt.difference(sent.packet.time).inMicroseconds,
  ],
);

/// Starts to deliver [count] messages on [port] in the MIDI isolate, one
/// every [interval], stamped with the time they arrive; the times are kept
/// in [_injected].
Future<void> _startInjecting(
  Midi midi,
  MidiPortId port,
  int count,
  Duration interval,
) => midi.withBackend((backend) {
  var sent = 0;
  Timer.periodic(interval, (timer) {
    final now = const MidiSystemClock().now();
    (backend as FakeMidiBackend).inject(
      port,
      MidiBytesPacket(bytes: MidiBytes([0x90, sent, 100]), time: now),
    );
    _injected.add(now.microseconds);
    if (++sent == count) timer.cancel();
  });
  return null;
});

/// The arrival times of the injected messages, in the MIDI isolate.
final _injected = <int>[];

Future<List<int>> _injectedTimes(Midi midi) =>
    midi.withBackend((_) => [..._injected]);

/// Blocks the calling isolate for [duration] without yielding.
void _block(Duration duration) {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {}
}

/// Returns the [p] percentile of the sorted [values].
int _percentile(List<int> values, double p) =>
    values[((values.length - 1) * p).round()];

Map<String, int> _stats(List<int> values) {
  final sorted = [...values]..sort();
  return {
    'count': sorted.length,
    'min': sorted.first,
    'median': _percentile(sorted, 0.5),
    'p95': _percentile(sorted, 0.95),
    'p99': _percentile(sorted, 0.99),
    'max': sorted.last,
  };
}

void main() {
  const block = Duration(milliseconds: 500);
  final report = <String, Object?>{};
  late Midi midi;

  setUp(() async {
    midi = await Midi.open(options: const MidiOptions(backend: _backend));
  });

  tearDown(() async => midi.close());

  tearDownAll(() {
    final path = Platform.environment['AUD_MIDI_REPORT'];
    if (path == null || report.isEmpty) return;
    File(
      path,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  });

  group('A blocked app isolate', () {
    test('does not delay notes scheduled before the block', () async {
      final output = midi.outputs.single;
      await output.send(const MidiActiveSensing());
      final start = midi.now();
      final sends = [
        for (var i = 0; i < 20; i++)
          output.send(
            MidiNoteOn(channel: 0, note: i, velocity: 100),
            at: start + Duration(milliseconds: 100 + 20 * i),
          ),
      ];
      _block(block);
      final unblocked = midi.now().difference(start);
      await Future.wait(sends);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final lateness = (await _lateness(midi)).skip(1).toList();
      final stats = _stats(lateness);
      report['scheduledSendDuringBlock'] = {
        'blockMs': unblocked.inMilliseconds,
        'latenessUs': stats,
      };
      expect(lateness, hasLength(20));
      expect(unblocked, greaterThanOrEqualTo(block));
      expect(stats['min'], greaterThanOrEqualTo(0));
      expect(
        stats['max'],
        lessThan(20000),
        reason: 'notes due during the block left on time: $stats',
      );
    });

    test('keeps the receive time of messages during the block', () async {
      final input = midi.inputs.single;
      final events = <MidiEvent>[];
      final received = <MidiTime>[];
      final subscription = input.messages.listen((event) {
        events.add(event);
        received.add(midi.now());
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final start = midi.now();
      await _startInjecting(
        midi,
        input.id,
        20,
        const Duration(milliseconds: 20),
      );
      _block(block);
      final unblocked = midi.now();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final injected = await _injectedTimes(midi);
      final duringBlock = [
        for (final time in injected)
          if (time < unblocked.microseconds) time,
      ];
      expect(events, hasLength(20));
      expect(duringBlock.length, greaterThanOrEqualTo(15));
      expect([for (final event in events) event.time.microseconds], injected);
      for (var i = 0; i < duringBlock.length; i++) {
        expect(received[i].isBefore(unblocked), isFalse);
      }
      report['receiveTimeDuringBlock'] = {
        'messages': events.length,
        'arrivedDuringBlock': duringBlock.length,
        'firstArrivalAfterStartMs':
            (injected.first - start.microseconds) ~/ 1000,
        'appReceivedFirstAfterMs': received.first
            .difference(start)
            .inMilliseconds,
        'timestampErrorUs': 0,
      };
      await subscription.cancel();
    });
  });
}
