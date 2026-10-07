// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:aud_midi/aud_midi.dart';

const _usage = '''
Usage: dart run aud_midi_cli <command> [arguments]

  list                           ports, devices and capabilities
  monitor [port]                 prints what an input receives, all inputs
                                 without a port, until Ctrl-C
  send <port> <hex bytes>        sends bytes, e.g. send "Synth" 90 3c 64
  note <port> <note> [ms]        plays a note for ms milliseconds (500)
  virtual <name>                 creates a virtual destination and source;
                                 prints what arrives and echoes it, until
                                 Ctrl-C
  network enable <name> [port]   enables the network session until Ctrl-C
  network connect <host> <port>  connects to a session and monitors it
  network browse [seconds]       lists the sessions in the network (5 s)

A port is a name, a part of a name or an id as `list` prints it.''';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    stdout.writeln(_usage);
    return;
  }
  final midi = await Midi.open();
  try {
    await switch (arguments) {
      ['list'] => _list(midi),
      ['monitor'] => _monitor(midi, midi.inputs),
      ['monitor', final port] => _monitor(midi, [_input(midi, port)]),
      ['send', final port, ...final bytes] when bytes.isNotEmpty => _send(
        _output(midi, port),
        bytes,
      ),
      ['note', final port, final note, ...final rest] => _note(
        midi,
        _output(midi, port),
        int.parse(note),
        rest.isEmpty ? 500 : int.parse(rest.first),
      ),
      ['virtual', final name] => _virtual(midi, name),
      ['network', 'enable', final name, ...final port] => _enable(
        midi,
        name,
        port.isEmpty ? null : int.parse(port.first),
      ),
      ['network', 'connect', final host, final port] => _connect(
        midi,
        host,
        int.parse(port),
      ),
      ['network', 'browse', ...final seconds] => _browse(
        midi,
        seconds.isEmpty ? 5 : int.parse(seconds.first),
      ),
      _ => Future(() => stdout.writeln(_usage)),
    };
  } on MidiException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } finally {
    await midi.close();
  }
}

/// Prints the ports, devices and capabilities.
Future<void> _list(Midi midi) async {
  stdout
    ..writeln('Backend: ${midi.backendName}')
    ..writeln('Capabilities: ${midi.capabilities}')
    ..writeln('Inputs:');
  for (final input in midi.inputs) {
    stdout.writeln('  ${_describe(input.info)}');
  }
  stdout.writeln('Outputs:');
  for (final output in midi.outputs) {
    stdout.writeln('  ${_describe(output.info)}');
  }
  stdout.writeln('Devices:');
  for (final device in midi.devices) {
    stdout.writeln(
      '  ${device.name} (${device.transport.name}, '
      '${device.ports.length} ports)',
    );
  }
}

/// Prints the messages of [inputs] until Ctrl-C.
Future<void> _monitor(Midi midi, List<MidiInput> inputs) async {
  final subscriptions = [
    for (final input in inputs)
      input.messages.listen(
        (event) => stdout.writeln(
          '${_ms(event.time)} ${input.info.name}: ${event.message}',
        ),
      ),
  ];
  final diagnostics = midi.diagnostics.listen(
    (diagnostic) => stderr.writeln(
      '! ${diagnostic.kind.name}: '
      '${diagnostic.cause}',
    ),
  );
  stdout.writeln('Monitoring ${inputs.length} input(s), Ctrl-C ends.');
  await ProcessSignal.sigint.watch().first;
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
  await diagnostics.cancel();
}

/// Sends the hex [bytes] to [output].
Future<void> _send(MidiOutput output, List<String> bytes) async {
  await output.sendBytes([
    for (final byte in bytes) int.parse(byte, radix: 16),
  ]);
  stdout.writeln('Sent ${bytes.join(' ')} to ${output.info.name}');
}

/// Plays [note] on [output] for [milliseconds], scheduled in the MIDI
/// isolate.
Future<void> _note(
  Midi midi,
  MidiOutput output,
  int note,
  int milliseconds,
) async {
  final now = midi.now();
  await output.send(MidiNoteOn(channel: 0, note: note, velocity: 100));
  await output.send(
    MidiNoteOff(channel: 0, note: note),
    at: now + Duration(milliseconds: milliseconds),
  );
  await Future<void>.delayed(Duration(milliseconds: milliseconds + 50));
  stdout.writeln('Played note $note on ${output.info.name}');
}

/// Creates a virtual destination and source named [name], prints what
/// arrives and echoes it, until Ctrl-C.
Future<void> _virtual(Midi midi, String name) async {
  final virtualPorts =
      midi.virtualPorts ?? (throw const MidiUnsupported('Virtual ports'));
  final destination = await virtualPorts.createDestination(name);
  final source = await virtualPorts.createSource(name);
  final echo = destination.messages.listen((event) {
    stdout.writeln('${_ms(event.time)} $name: ${event.message}');
    unawaited(source.send(event.message));
  });
  stdout.writeln('Created "$name" as destination and source, Ctrl-C ends.');
  await ProcessSignal.sigint.watch().first;
  await echo.cancel();
  await virtualPorts.remove(destination.id);
  await virtualPorts.remove(source.id);
}

/// Enables the network session as [name] and prints its changes until
/// Ctrl-C.
Future<void> _enable(Midi midi, String name, int? port) async {
  final network = _network(midi);
  final changes = network.sessionChanges.listen(_printSession);
  _printSession(await network.enable(name: name, port: port));
  stdout.writeln('Session enabled, Ctrl-C ends.');
  await ProcessSignal.sigint.watch().first;
  await changes.cancel();
  await network.disable();
}

/// Connects to the session at [host] and [port] and monitors it.
Future<void> _connect(Midi midi, String host, int port) async {
  final network = _network(midi);
  if (!network.session.enabled) await network.enable(name: 'aud_midi_cli');
  final connection = await network.connect(host, port);
  stdout.writeln('Connected: ${connection.state.name}');
  await _monitor(midi, [
    for (final id in connection.portIds)
      if (midi.input(id) case final MidiInput input) input,
  ]);
  await network.disconnect(connection.host);
}

/// Lists the sessions in the network for [seconds].
Future<void> _browse(Midi midi, int seconds) async {
  final hosts = await _network(midi)
      .browse()
      .timeout(Duration(seconds: seconds), onTimeout: (sink) => sink.close())
      .fold(<MidiNetworkHostInfo>[], (_, hosts) => hosts);
  for (final host in hosts) {
    stdout.writeln('${host.name}  ${host.address}:${host.port}');
  }
  if (hosts.isEmpty) stdout.writeln('No session found.');
}

MidiNetwork _network(Midi midi) =>
    midi.network ?? (throw const MidiUnsupported('Network sessions'));

void _printSession(MidiNetworkSessionInfo session) => stdout.writeln(
  'Session "${session.localName}" on port ${session.port}: '
  '${session.enabled ? 'enabled' : 'disabled'}, '
  '${session.connections.length} connection(s)',
);

MidiInput _input(Midi midi, String port) => midi.inputs.firstWhere(
  (input) => _matches(input.info, port),
  orElse: () => throw FormatException('No input "$port"'),
);

MidiOutput _output(Midi midi, String port) => midi.outputs.firstWhere(
  (output) => _matches(output.info, port),
  orElse: () => throw FormatException('No output "$port"'),
);

bool _matches(MidiPortInfo info, String port) =>
    info.id.value == port || info.name.contains(port);

String _describe(MidiPortInfo port) =>
    '${port.name}  [${port.id.value}] ${port.transport.name}, '
    '${port.protocol.name}${port.isOwn ? ', own' : ''}';

String _ms(MidiTime time) =>
    (time.microseconds / 1000).toStringAsFixed(3).padLeft(12);
