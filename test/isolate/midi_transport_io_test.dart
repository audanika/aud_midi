// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host_command.dart';
import 'package:aud_midi/src/isolate/midi_host_notice.dart';
import 'package:aud_midi/src/isolate/midi_host_snapshot.dart';
import 'package:aud_midi/src/isolate/midi_port_link.dart';
import 'package:aud_midi/src/isolate/midi_transport_io.dart';
import 'package:test/test.dart';

MidiBackend _fake() => FakeMidiBackend();

void main() {
  group('midi_transport_io', () {
    test('supports MIDI isolates', () {
      expect(midiIsolatesSupported, isTrue);
    });

    test('spawns a host and links to it', () async {
      final connector = await midiSpawnHost(const MidiOptions(backend: _fake));
      final notices = StreamController<MidiHostNotice>();
      final link = midiRemoteLink(connector: connector, onNotice: notices.add);
      expect(link, isA<MidiPortLink>());
      link.send(MidiHelloCommand(request: 1, sink: link.sink));
      final hello = StreamIterator(notices.stream);
      await hello.moveNext();
      final snapshot =
          (hello.current as MidiReplyNotice).value! as MidiHostSnapshot;
      expect(snapshot.backend, 'fake');
      link.send(MidiGoodbyeCommand(proxy: snapshot.proxy, request: 2));
      await hello.moveNext();
      link.close();
    });
  });
}
