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
import 'package:aud_midi/src/isolate/midi_host_snapshot.dart';
import 'package:aud_midi/src/isolate/midi_isolate_launcher.dart';
import 'package:aud_midi/src/isolate/midi_port_link.dart';
import 'package:test/test.dart';

/// The backend of the platform in these tests: a fake named `platform`.
MidiBackend _platform(MidiOptions options) =>
    FakeMidiBackend(name: options.clientName);

/// A fake named `custom`.
MidiBackend _custom() => FakeMidiBackend(name: 'custom');

/// A fake that refuses to start.
MidiBackend _refusing() =>
    FakeMidiBackend()
      ..failWith(start: const MidiPermissionDenied(MidiPermission.midi));

/// A fake that fails to start with an error that cannot leave the isolate.
MidiBackend _unsendable() =>
    FakeMidiBackend()..failWith(start: _Unsendable(ReceivePort()));

/// A factory that ends the isolate.
MidiBackend _exiting() => Isolate.exit();

/// An error that holds a port, so it cannot leave its isolate.
final class _Unsendable implements Exception {
  _Unsendable(this.port);

  final ReceivePort port;

  @override
  String toString() => 'unsendable';
}

/// Throws in the MIDI isolate after the current turn.
Object? _throwLater(MidiBackend backend) {
  Timer.run(() => throw StateError('nobody caught me'));
  return null;
}

void main() {
  // Starts a MIDI isolate and connects a link to it.
  Future<
    ({
      MidiConnector connector,
      MidiPortLink link,
      StreamIterator<MidiHostNotice> notices,
    })
  >
  launch(MidiOptions options) async {
    final connector = await spawnMidiIsolate(
      options: options,
      platformBackend: _platform,
    );
    final notices = StreamController<MidiHostNotice>();
    final link = MidiPortLink(connector: connector, onNotice: notices.add);
    return (
      connector: connector,
      link: link,
      notices: StreamIterator(notices.stream.expand(_flatten)),
    );
  }

  group('spawnMidiIsolate(options, platformBackend)', () {
    test('runs the host until its last proxy left', () async {
      final (:connector, :link, :notices) = await launch(
        const MidiOptions(clientName: 'platform'),
      );
      expect(connector.isLocal, isFalse);
      expect(connector.isolate, isA<Isolate>());
      link.send(MidiHelloCommand(request: 1, sink: link.sink));
      expect(await notices.moveNext(), isTrue);
      final snapshot =
          (notices.current as MidiReplyNotice).value! as MidiHostSnapshot;
      expect(snapshot.backend, 'platform');
      link.send(MidiGoodbyeCommand(proxy: snapshot.proxy, request: 2));
      expect(await notices.moveNext(), isTrue);
      expect((notices.current as MidiReplyNotice).value, isTrue);
      expect(await notices.moveNext(), isTrue);
      expect(notices.current, isA<MidiHostExitNotice>());
      link.close();
    });

    test('creates the backend of the options', () async {
      final (:connector, :link, :notices) = await launch(
        const MidiOptions(backend: _custom),
      );
      link.send(MidiHelloCommand(request: 1, sink: link.sink));
      await notices.moveNext();
      final snapshot =
          (notices.current as MidiReplyNotice).value! as MidiHostSnapshot;
      expect(snapshot.backend, 'custom');
      link.send(MidiGoodbyeCommand(proxy: snapshot.proxy, request: 2));
      await notices.moveNext();
      link.close();
    });

    test('reports errors nobody caught as diagnostics', () async {
      final (:connector, :link, :notices) = await launch(
        const MidiOptions(backend: _custom),
      );
      link
        ..send(MidiHelloCommand(request: 1, sink: link.sink))
        ..send(
          const MidiWithBackendCommand(
            proxy: 1,
            request: 2,
            action: _throwLater,
          ),
        );
      final reported = <MidiDiagnostic>[];
      while (reported.isEmpty && await notices.moveNext()) {
        if (notices.current case MidiDiagnosticsNotice(:final diagnostics)) {
          reported.addAll(diagnostics);
        }
      }
      expect(
        reported.single.cause,
        'Uncaught error in the MIDI isolate: Bad state: nobody caught me',
      );
      link.send(const MidiGoodbyeCommand(proxy: 1, request: 3));
      await notices.moveNext();
      link.close();
    });

    test('rethrows what the start threw', () async {
      await expectLater(
        spawnMidiIsolate(
          options: const MidiOptions(backend: _refusing),
          platformBackend: _platform,
        ),
        throwsA(
          isA<MidiPermissionDenied>().having(
            (e) => e.permission,
            'permission',
            MidiPermission.midi,
          ),
        ),
      );
    });

    test('replaces an error that cannot leave the isolate', () async {
      await expectLater(
        spawnMidiIsolate(
          options: const MidiOptions(backend: _unsendable),
          platformBackend: _platform,
        ),
        throwsA(
          isA<MidiRemoteError>()
              .having((e) => e.type, 'type', '_Unsendable')
              .having((e) => e.message, 'message', 'unsendable'),
        ),
      );
    });

    test('fails when the isolate ends during its start', () async {
      await expectLater(
        spawnMidiIsolate(
          options: const MidiOptions(backend: _exiting),
          platformBackend: _platform,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'The MIDI isolate ended during its start',
          ),
        ),
      );
    });
  });
}

/// Returns the notices of [notice], unpacking batches.
Iterable<MidiHostNotice> _flatten(MidiHostNotice notice) =>
    notice is MidiNoticeBatch ? notice.notices.expand(_flatten) : [notice];
