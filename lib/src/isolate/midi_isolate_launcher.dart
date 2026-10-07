// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';

import 'package:aud_midi_core/aud_midi_core.dart';

import '../api/midi_connector.dart';
import '../api/midi_options.dart';
import '../api/midi_remote_error.dart';
import 'midi_host.dart';
import 'midi_port_link.dart';

// #############################################################################
/// What a MIDI isolate gets to start: the [options], the function that
/// selects the backend of the platform, and the port for its answer.
typedef MidiIsolateSetup = ({
  MidiOptions options,
  MidiBackend Function(MidiOptions options) platformBackend,
  SendPort reply,
});

// #############################################################################
/// Spawns a MIDI isolate whose host runs the backend [options] ask for,
/// or the one [platformBackend] selects, and returns the connector of the
/// host.
///
/// Throws what creating or starting the backend threw, e.g. a
/// `MidiPermissionDenied`; the MIDI isolate has ended then.
Future<MidiConnector> spawnMidiIsolate({
  required MidiOptions options,
  required MidiBackend Function(MidiOptions options) platformBackend,
}) async {
  final replies = ReceivePort('aud_midi start');
  try {
    final isolate = await Isolate.spawn<MidiIsolateSetup>(
      midiIsolateMain,
      (
        options: options,
        platformBackend: platformBackend,
        reply: replies.sendPort,
      ),
      debugName: 'aud_midi',
      onExit: replies.sendPort,
    );
    return switch (await replies.first) {
      (final SendPort port, final int host) => MidiConnector(
        host: host,
        port: port,
        isolate: Isolate(isolate.controlPort),
      ),
      (final Object error, final String stack) => Error.throwWithStackTrace(
        error,
        StackTrace.fromString(stack),
      ),
      _ => throw StateError('The MIDI isolate ended during its start'),
    };
  } finally {
    replies.close();
  }
}

// #############################################################################
/// Runs a MIDI host in the current isolate until its last proxy left, then
/// ends the isolate.
///
/// It answers [setup] with the command port and the id of the host, or with
/// the error of the start. Errors nobody catches become diagnostics of the
/// host instead of ending the isolate.
void midiIsolateMain(MidiIsolateSetup setup) {
  MidiHost? host;
  runZonedGuarded(() async {
    final started = host = await _start(setup);
    if (started == null) Isolate.exit();
    final commands = ReceivePort('aud_midi commands')
      ..listen((message) => started.handle(MidiPortLink.commandOf(message)));
    setup.reply.send((commands.sendPort, started.id));
    await started.done;
    commands.close();
    Isolate.exit();
  }, (error, stack) => host?.reportError(error, stack));
}

// #############################################################################
/// Creates and starts the host of [setup], or answers with the error and
/// returns null.
Future<MidiHost?> _start(MidiIsolateSetup setup) async {
  try {
    final factory = setup.options.backend;
    final host = MidiHost(
      backend: factory == null
          ? setup.platformBackend(setup.options)
          : factory(),
      options: setup.options.engineFor(inMidiIsolate: true),
    );
    await host.start();
    return host;
  } on Object catch (error, stack) {
    try {
      setup.reply.send((error, '$stack'));
    } on Object {
      setup.reply.send((
        MidiRemoteError(type: '${error.runtimeType}', message: '$error'),
        '$stack',
      ));
    }
    return null;
  }
}
