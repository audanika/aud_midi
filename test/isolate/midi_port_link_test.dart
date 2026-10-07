// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host_command.dart';
import 'package:aud_midi/src/isolate/midi_host_notice.dart';
import 'package:aud_midi/src/isolate/midi_port_link.dart';
import 'package:test/test.dart';

/// Creates a link to [commands] in a new isolate, watches the proxy 7 and
/// lets the isolate end.
Future<void> _watchAndExit(SendPort commands) => Isolate.run(() {
  MidiPortLink(
    connector: MidiConnector(host: 1, port: commands),
    onNotice: (_) {},
  ).watch(proxy: 7);
});

/// Ends right away.
void _exit(Object? _) {}

void main() {
  late ReceivePort commands;
  late StreamIterator<Object?> received;

  setUp(() {
    commands = ReceivePort();
    received = StreamIterator(commands);
  });

  tearDown(() async => received.cancel());

  group('MidiPortLink', () {
    group('send(command)', () {
      test('sends the command to the port of the host', () async {
        final link = MidiPortLink(
          connector: MidiConnector(host: 1, port: commands.sendPort),
          onNotice: (_) {},
        );
        addTearDown(link.close);
        link.send(const MidiDiagnosticsCommand(proxy: 2, request: 3));
        expect(await received.moveNext(), isTrue);
        expect(
          received.current,
          isA<MidiDiagnosticsCommand>().having((c) => c.request, 'request', 3),
        );
      });
    });

    group('sink', () {
      test('delivers notices to onNotice', () async {
        final notices = StreamController<MidiHostNotice>();
        final link = MidiPortLink(
          connector: MidiConnector(host: 1, port: commands.sendPort),
          onNotice: notices.add,
        );
        addTearDown(link.close);
        link.sink(const MidiReplyNotice(request: 5, value: 'v'));
        final notice = await notices.stream.first as MidiReplyNotice;
        expect((notice.request, notice.value), (5, 'v'));
        expect(link.onNotice, isNotNull);
      });
    });

    group('watch(proxy)', () {
      test('says goodbye for the proxy when its isolate ends', () async {
        await _watchAndExit(commands.sendPort);
        expect(await received.moveNext(), isTrue);
        final goodbye = MidiPortLink.commandOf(received.current);
        expect(
          goodbye,
          isA<MidiGoodbyeCommand>()
              .having((c) => c.proxy, 'proxy', 7)
              .having((c) => c.request, 'request', 0),
        );
      });
    });

    group('MidiPortLink()', () {
      test('tells when the MIDI isolate ends', () async {
        final exited = ReceivePort();
        final isolate = await Isolate.spawn(
          _exit,
          null,
          paused: true,
          onExit: exited.sendPort,
        );
        final notices = StreamController<MidiHostNotice>();
        final link = MidiPortLink(
          connector: MidiConnector(
            host: 1,
            port: commands.sendPort,
            isolate: Isolate(isolate.controlPort),
          ),
          onNotice: notices.add,
        );
        addTearDown(link.close);
        isolate.resume(isolate.pauseCapability!);
        await exited.first;
        expect(await notices.stream.first, isA<MidiHostExitNotice>());
      });
    });

    group('close()', () {
      test('stops watching', () async {
        final link = MidiPortLink(
          connector: MidiConnector(host: 1, port: commands.sendPort),
          onNotice: (_) => fail('no notice after close'),
        )..watch(proxy: 3);
        link.close();
        link.sink(const MidiHostExitNotice());
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    });

    group('commandOf(message)', () {
      test('returns commands as they are', () {
        const command = MidiStopScanCommand(proxy: 1, request: 2);
        expect(MidiPortLink.commandOf(command), same(command));
      });

      test('turns the exit message of a proxy into its goodbye', () {
        expect(
          MidiPortLink.commandOf([MidiPortLink.goodbye, 4]),
          isA<MidiGoodbyeCommand>().having((c) => c.proxy, 'proxy', 4),
        );
      });

      test('throws for anything else', () {
        for (final message in [
          'x',
          null,
          3,
          [MidiPortLink.goodbye],
        ]) {
          expect(
            () => MidiPortLink.commandOf(message),
            throwsA(isA<ArgumentError>()),
            reason: '$message',
          );
        }
      });
    });

    group('hostExit', () {
      test('names the exit message of the MIDI isolate', () {
        expect(MidiPortLink.hostExit, 'aud_midi:host-exit');
        expect(MidiPortLink.goodbye, 'aud_midi:goodbye');
      });
    });
  });
}
