// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host.dart';
import 'package:aud_midi/src/isolate/midi_host_command.dart';
import 'package:aud_midi/src/isolate/midi_host_notice.dart';
import 'package:aud_midi/src/isolate/midi_host_snapshot.dart';
import 'package:aud_midi/src/isolate/midi_local_link.dart';
import 'package:test/test.dart';

void main() {
  late MidiHost host;
  late List<MidiHostNotice> notices;
  late MidiLocalLink link;

  Future<void> pump() async {
    for (var turn = 0; turn < 3; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    host = MidiHost(backend: FakeMidiBackend());
    await host.start();
    notices = [];
    link = MidiLocalLink(host: host, onNotice: notices.add);
  });

  tearDown(() async {
    if (host.proxyCount == 0) {
      await host.engine.close();
      return;
    }
    host.handle(const MidiGoodbyeCommand(proxy: 1, request: 99));
    await host.done;
  });

  group('MidiLocalLink', () {
    group('send(command), sink', () {
      test('hand commands and notices over asynchronously', () async {
        link.send(MidiHelloCommand(request: 1, sink: link.sink));
        expect(host.proxyCount, 0);
        await pump();
        expect(host.proxyCount, 1);
        final reply = notices.single as MidiReplyNotice;
        expect(reply.request, 1);
        expect((reply.value! as MidiHostSnapshot).proxy, 1);
      });
    });

    group('watch(proxy)', () {
      test('does nothing', () {
        link.watch(proxy: 1);
        expect(link.isClosed, isFalse);
      });
    });

    group('close()', () {
      test('drops the notices that arrive afterwards', () async {
        link.send(MidiHelloCommand(request: 1, sink: link.sink));
        link.close();
        expect(link.isClosed, isTrue);
        await pump();
        expect(host.proxyCount, 1);
        expect(notices, isEmpty);
      });
    });

    group('host, onNotice', () {
      test('keep the given values', () {
        expect(link.host, same(host));
        link.onNotice(const MidiHostExitNotice());
        expect(notices.single, isA<MidiHostExitNotice>());
      });
    });
  });
}
