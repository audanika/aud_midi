// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi/aud_midi.dart';

// Measures the acceptance criteria of the aud_midi plan on this machine.
//
// The far end of every measurement is a second MIDI host of this process,
// run by a worker isolate: it has a MIDI isolate and a client of the
// operating system of its own and offers a virtual destination and a
// virtual source, like another app would. The app isolate of the bench
// talks to it through the platform's MIDI system. `--loopback <port>` adds
// a round trip through a native loopback, e.g. the IAC bus on macOS or a
// cable between two ports.

const _usage = '''
Usage: dart run midi_bench [--loopback <port>] [--count <n>] [--json <file>]

  --loopback <port>  also measures the round trip through a native
                     loopback whose input and output are named <port>
  --count <n>        messages per measurement (200)
  --json <file>      writes the results as JSON''';

Future<void> main(List<String> arguments) async {
  final options = _parse(arguments);
  if (options == null) {
    stdout.writeln(_usage);
    exitCode = 64;
    return;
  }
  final midi = await Midi.open(
    options: const MidiOptions(clientName: 'midi_bench'),
  );
  final far = await _FarEnd.start();
  final results = <String, Object?>{
    'backend': midi.backendName,
    'os': Platform.operatingSystemVersion,
    'dart': Platform.version.split(' ').first,
  };
  try {
    final toFar = await _port(() => midi.outputs, far.inputName);
    final fromFar = await _port(() => midi.inputs, far.outputName);
    stdout.writeln('Far end: ${toFar.info.name} / ${fromFar.info.name}');
    results['roundTripVirtual'] = await _roundTrip(
      midi,
      toFar,
      fromFar,
      options.count,
      echo: far,
    );
    final loopback = options.loopback;
    if (loopback != null) {
      final output = await _port(() => midi.outputs, loopback);
      final input = await _port(() => midi.inputs, loopback);
      final online = [
        output.info,
        input.info,
      ].every((port) => port.state == MidiPortState.connected);
      results['roundTripLoopback'] = online
          ? await _roundTrip(midi, output, input, options.count)
          : {'skipped': '${output.info.name} is ${output.info.state.name}'};
    }
    results['schedulingUnderLoad'] = await _scheduling(
      midi,
      toFar,
      far,
      options.count,
    );
    results['fragmentedSysEx'] = await _sysEx(midi, toFar, far);
    results['overflow'] = await _overflow(midi, toFar, far);
    results['hotplug'] = await _hotplug(midi, far);
  } finally {
    await far.stop();
    await midi.close();
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(results));
  final json = options.json;
  if (json != null) File(json).writeAsStringSync(jsonEncode(results));
}

// .............................................................................
/// Measures the time from the send call to the timestamp of the echo and
/// to its arrival in the app isolate, one message at a time.
Future<Map<String, Object?>> _roundTrip(
  Midi midi,
  MidiOutput output,
  MidiInput input,
  int count, {
  _FarEnd? echo,
}) async {
  await echo?.command(['echo', true]);
  var expected = -1;
  var arrival = Completer<(MidiEvent, MidiTime)>();
  final subscription = input
      .messagesWith(const MidiInputOptions(deliverAs: MidiProtocol.midi1))
      .listen((event) {
        if (event.message case MidiNoteOn(:final note) when note == expected) {
          if (!arrival.isCompleted) arrival.complete((event, midi.now()));
        }
      });
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final stamp = <int>[];
  final app = <int>[];
  var lost = 0;
  const warmUp = 20;
  for (var i = 0; i < warmUp + count; i++) {
    expected = i % 128;
    arrival = Completer();
    final sent = midi.now();
    await output.send(
      MidiNoteOn(channel: 0, note: expected, velocity: 1 + i % 127),
    );
    try {
      final (event, arrived) = await arrival.future.timeout(
        const Duration(seconds: 1),
      );
      if (i < warmUp) continue;
      stamp.add(event.time.difference(sent).inMicroseconds);
      app.add(arrived.difference(sent).inMicroseconds);
    } on TimeoutException {
      if (i >= warmUp) lost++;
    }
  }
  await subscription.cancel();
  await echo?.command(['echo', false]);
  final result = {
    'messages': count,
    'lost': lost,
    'sendToEchoStampUs': _stats(stamp),
    'sendToAppUs': _stats(app),
  };
  final appStats = _stats(app);
  stdout.writeln(
    'Round trip ${output.info.name}: app median '
    '${_ms(appStats['median'] ?? 0)} ms, '
    'p99 ${_ms(appStats['p99'] ?? 0)} ms, $lost lost',
  );
  return result;
}

// .............................................................................
/// Schedules [count] notes for the far end, 5 ms apart, and keeps the app
/// isolate busy until the last is due; the far end measures when they
/// arrive. Once for the destination of the far end, which the operating
/// system schedules where it can, and once for an own virtual source, which
/// the MIDI isolate schedules in software.
Future<Map<String, Object?>> _scheduling(
  Midi midi,
  MidiOutput toFar,
  _FarEnd far,
  int count,
) async {
  final result = <String, Object?>{};
  final source = await midi.virtualPorts?.createSource('midi_bench source');
  final targets = <String, MidiOutput>{
    'toDestination': toFar,
    'fromOwnSource': ?source,
  };
  if (source != null) {
    await far.command(['listen', source.info.name]);
  }
  for (final MapEntry(key: name, value: output) in targets.entries) {
    await far.command(['record', true]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final start = midi.now() + const Duration(milliseconds: 100);
    for (var i = 0; i < count; i++) {
      unawaited(
        output.send(
          MidiNoteOn(channel: 2, note: i % 128, velocity: 64),
          at: start + Duration(milliseconds: 5 * i),
        ),
      );
    }
    final busy = start + Duration(milliseconds: 5 * count + 20);
    _keepBusyUntil(midi, busy);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final records = await far.command(['record', false]) as List<Object?>;
    final lateness = <int>[];
    final stampError = <int>[];
    for (final record in records.cast<List<Object?>>()) {
      final [index as int, stamp as int, arrival as int, _] = record;
      final due = start + Duration(milliseconds: 5 * index);
      lateness.add(arrival - due.microseconds);
      stampError.add(stamp - due.microseconds);
    }
    result[name] = {
      'scheduled': count,
      'arrived': records.length,
      'arrivalMinusDueUs': _stats(lateness),
      'stampMinusDueUs': _stats(stampError),
    };
    stdout.writeln(
      'Scheduling $name under load: p95 '
      '${_ms(_stats(lateness)['p95'] ?? 0)} ms, p99 '
      '${_ms(_stats(lateness)['p99'] ?? 0)} ms late',
    );
  }
  if (source != null) await midi.virtualPorts!.remove(source.id);
  return result;
}

// .............................................................................
/// Sends a System Exclusive message of 1000 bytes as Universal MIDI
/// Packets with a Timing Clock between every packet and checks the order
/// and the content at the far end.
Future<Map<String, Object?>> _sysEx(
  Midi midi,
  MidiOutput toFar,
  _FarEnd far,
) async {
  await far.command(['collect', true]);
  final data = Uint8List.fromList([for (var i = 0; i < 1000; i++) i % 128]);
  final sysEx = MidiSysEx(data).toUmp(group: 0);
  final clock = const MidiTimingClock().toUmp(group: 0).single;
  final words = [
    for (final ump in sysEx) ...[...ump.words, ...clock.words],
  ];
  if (toFar.info.capabilities.ump) {
    await toFar.sendUmp(words);
  } else {
    await toFar.sendBytes([
      ...MidiSysEx(data).toBytes()!.bytes.take(500),
      0xF8,
      ...MidiSysEx(data).toBytes()!.bytes.skip(500),
    ]);
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final collected = (await far.command(['collect', false]) as List<Object?>)
      .cast<String>();
  final clocks = collected.where((kind) => kind == 'clock').length;
  final sysExIndex = collected.indexOf('sysex:${data.length}:ok');
  final result = {
    'packets': sysEx.length,
    'clocksBetween': toFar.info.capabilities.ump ? sysEx.length : 1,
    'clocksReceived': clocks,
    'sysExReassembled': sysExIndex >= 0,
    'clocksBeforeSysEx': sysExIndex < 0
        ? 0
        : collected.take(sysExIndex).where((kind) => kind == 'clock').length,
  };
  stdout.writeln('Fragmented SysEx: $result');
  return result;
}

// .............................................................................
/// Lets the far end pause a listener with a small queue and floods it with
/// 1000 Control Changes and a Stop; returns what was kept, what the
/// diagnostics reported as dropped and whether that adds up.
Future<Map<String, Object?>> _overflow(
  Midi midi,
  MidiOutput toFar,
  _FarEnd far,
) async {
  const capacity = 64;
  const sent = 1000;
  await far.command(['overflow', capacity]);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  for (var i = 0; i < sent; i++) {
    unawaited(
      toFar.send(MidiControlChange(channel: 0, controller: 1, value: i % 128)),
    );
  }
  await toFar.send(const MidiStop());
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final [received as int, dropped as int, diagnostics as int] =
      await far.command(['resume']) as List<Object?>;
  final result = {
    'sent': sent,
    'capacity': capacity,
    'received': received,
    'droppedByDiagnostics': dropped,
    'diagnostics': diagnostics,
    'accountedFor': received + dropped == sent + 1,
  };
  stdout.writeln('Overflow: $result');
  return result;
}

// .............................................................................
/// Lets the far end create and remove a port while the app has it open;
/// measures how fast the app learns it and checks the state afterwards.
Future<Map<String, Object?>> _hotplug(Midi midi, _FarEnd far) async {
  final name = 'midi_bench hotplug ${Random().nextInt(1 << 20)}';
  final events = StreamIterator(midi.changes);
  final created = midi.now();
  await far.command(['create', name]);
  var added = Duration.zero;
  while (await events.moveNext().timeout(const Duration(seconds: 5))) {
    if (events.current case MidiPortAdded(:final port) when port.name == name) {
      added = midi.now().difference(created);
      break;
    }
  }
  final output = midi.outputs.firstWhere((output) => output.info.name == name);
  await output.send(const MidiStart());
  final removed = midi.now();
  await far.command(['remove', name]);
  var gone = Duration.zero;
  while (await events.moveNext().timeout(const Duration(seconds: 5))) {
    if (events.current case MidiPortRemoved(
      :final port,
    ) when port.name == name) {
      gone = midi.now().difference(removed);
      break;
    }
  }
  await events.cancel();
  Object? afterRemoval;
  try {
    await output.send(const MidiStop());
    afterRemoval = 'sent';
  } on MidiPortGone {
    afterRemoval = 'MidiPortGone';
  }
  final result = {
    'addedAfterMs': added.inMicroseconds / 1000,
    'removedAfterMs': gone.inMicroseconds / 1000,
    'sendAfterRemoval': afterRemoval,
  };
  stdout.writeln('Hotplug: $result');
  return result;
}

// .............................................................................
/// The second MIDI host: a worker isolate with a MIDI isolate of its own.
final class _FarEnd {
  _FarEnd._(this._commands, this._replies, this.inputName, this.outputName);

  /// Starts the worker and waits for its ports.
  static Future<_FarEnd> start() async {
    final replies = ReceivePort();
    final iterator = StreamIterator(replies);
    final suffix = Random().nextInt(1 << 20);
    await Isolate.spawn(_farEndMain, (replies.sendPort, suffix));
    await iterator.moveNext();
    final [commands as SendPort, input as String, output as String] =
        iterator.current! as List<Object?>;
    return _FarEnd._(commands, iterator, input, output);
  }

  /// Sends [command] and returns the answer.
  Future<Object?> command(List<Object?> command) async {
    _commands.send(command);
    await _replies.moveNext();
    return _replies.current;
  }

  /// Ends the worker.
  Future<void> stop() async {
    await command(['stop']);
    await _replies.cancel();
  }

  final SendPort _commands;
  final StreamIterator<Object?> _replies;

  /// The name of the destination of the far end, an output for the bench.
  final String inputName;

  /// The name of the source of the far end, an input for the bench.
  final String outputName;
}

/// Runs the far end: answers every command on the port of [setup].
Future<void> _farEndMain((SendPort, int) setup) async {
  final (replies, suffix) = setup;
  final midi = await Midi.open(
    options: const MidiOptions(clientName: 'midi_bench far end'),
  );
  final destination = await midi.virtualPorts!.createDestination(
    'midi_bench in $suffix',
  );
  final source = await midi.virtualPorts!.createSource(
    'midi_bench out $suffix',
  );
  final commands = ReceivePort();
  var echo = false;
  List<List<int>>? records;
  List<String>? collected;
  var overflowReceived = 0;
  var overflowDropped = 0;
  var overflowDiagnostics = 0;
  StreamSubscription<MidiEvent>? paused;
  final created = <String, MidiInput>{};

  void onEvent(MidiEvent event) {
    final arrival = midi.now().microseconds;
    if (echo) unawaited(source.send(event.message));
    final recording = records;
    if (event.message case MidiNoteOn(
      :final note,
      channel: 2,
    ) when recording != null) {
      recording.add([recording.length, event.time.microseconds, arrival, note]);
    }
    switch (event.message) {
      case MidiTimingClock():
        collected?.add('clock');
      case MidiSysEx(:final data):
        final ok = [
          for (var i = 0; i < data.length; i++)
            if (data[i] != i % 128) i,
        ].isEmpty;
        collected?.add('sysex:${data.length}:${ok ? 'ok' : 'corrupt'}');
      default:
        break;
    }
  }

  final listening = <StreamSubscription<MidiEvent>>[
    destination.messages.listen(onEvent),
  ];
  midi.diagnostics.listen((diagnostic) {
    if (diagnostic.kind == MidiDiagnosticKind.queueOverflow) {
      overflowDropped += diagnostic.count;
      overflowDiagnostics++;
    }
  });
  replies.send([commands.sendPort, destination.info.name, source.info.name]);

  await for (final message in commands) {
    final command = message! as List<Object?>;
    switch (command) {
      case ['echo', final bool on]:
        echo = on;
        replies.send(null);
      case ['record', true]:
        records = [];
        replies.send(null);
      case ['record', false]:
        replies.send(records);
        records = null;
      case ['listen', final String name]:
        final input = await _port(() => midi.inputs, name);
        listening.add(input.messages.listen(onEvent));
        replies.send(null);
      case ['collect', true]:
        collected = [];
        replies.send(null);
      case ['collect', false]:
        replies.send(collected);
        collected = null;
      case ['overflow', final int capacity]:
        paused = destination
            .messagesWith(MidiInputOptions(queueCapacity: capacity))
            .listen((event) {
              if (event.message is MidiControlChange) overflowReceived++;
            });
        paused.pause();
        replies.send(null);
      case ['resume']:
        paused!.resume();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await paused.cancel();
        replies.send([overflowReceived, overflowDropped, overflowDiagnostics]);
      case ['create', final String name]:
        created[name] = await midi.virtualPorts!.createDestination(name);
        replies.send(null);
      case ['remove', final String name]:
        await midi.virtualPorts!.remove(created.remove(name)!.id);
        replies.send(null);
      default:
        for (final subscription in listening) {
          await subscription.cancel();
        }
        await midi.close();
        commands.close();
        replies.send(null);
    }
  }
}

// .............................................................................
/// Waits until [name] appears among the ports [handles] returns.
Future<T> _port<T extends Object>(
  List<T> Function() handles,
  String name,
) async {
  for (var i = 0; i < 300; i++) {
    for (final handle in handles()) {
      final info = handle is MidiInput
          ? handle.info
          : (handle as MidiOutput).info;
      if (info.name.contains(name)) return handle;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('No port named $name');
}

/// Keeps the calling isolate busy without yielding until [end].
void _keepBusyUntil(Midi midi, MidiTime end) {
  var x = 0.0;
  while (midi.now().isBefore(end)) {
    for (var i = 0; i < 1000; i++) {
      x = sin(x + i);
    }
  }
  if (x.isNaN) stdout.writeln('');
}

Map<String, int> _stats(List<int> values) {
  if (values.isEmpty) return const {'count': 0};
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

String _ms(int microseconds) => (microseconds / 1000).toStringAsFixed(3);

({String? loopback, int count, String? json})? _parse(List<String> arguments) {
  String? loopback;
  String? json;
  var count = 200;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--loopback' when i + 1 < arguments.length:
        loopback = arguments[++i];
      case '--count' when i + 1 < arguments.length:
        count = int.tryParse(arguments[++i]) ?? 0;
      case '--json' when i + 1 < arguments.length:
        json = arguments[++i];
      default:
        return null;
    }
  }
  return count > 0 ? (loopback: loopback, count: count, json: json) : null;
}
