// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host_notice.dart';
import 'package:test/test.dart';

void main() {
  group('MidiHostNotice', () {
    var request = 4;
    var stream = 5;
    final port = MidiPortInfo(
      id: const MidiPortId('fake:in'),
      name: 'in',
      direction: MidiDirection.input,
    );
    var diagnostic = const MidiDiagnostic(
      kind: MidiDiagnosticKind.parserReset,
      cause: 'c',
      time: MidiTime.zero,
    );
    final session = MidiNetworkSessionInfo(
      localName: 'n',
      enabled: true,
      port: 5004,
      protocol: MidiNetworkProtocol.appleMidi,
      connectionPolicy: MidiNetworkConnectionPolicy.anyone,
    );

    test('the answers carry their request', () {
      final reply = MidiReplyNotice(request: request, value: 'v');
      expect((reply.request, reply.value), (request, 'v'));
      expect(MidiReplyNotice(request: request).value, isNull);
      final failure = MidiFailureNotice(
        request: request,
        error: StateError('e'),
        stack: 's',
      );
      expect(failure.request, request);
      expect(failure.error, isA<StateError>());
      expect(failure.stack, 's');
    });

    test('a batch keeps its notices in order', () {
      final first = MidiReplyNotice(request: request);
      final second = MidiStreamDoneNotice(stream: stream);
      expect(
        MidiNoticeBatch(notices: [first, second]).notices,
        equals([first, second]),
      );
    });

    test('the broadcast notices carry their state', () {
      expect(
        MidiPortsNotice(events: [MidiPortAdded(port: port)]).events,
        equals([MidiPortAdded(port: port)]),
      );
      expect(
        MidiDiagnosticsNotice(diagnostics: [diagnostic]).diagnostics,
        equals([diagnostic]),
      );
      expect(
        MidiCapabilitiesNotice(
          capabilities: MidiCapabilities(ump: true),
        ).capabilities,
        MidiCapabilities(ump: true),
      );
      expect(MidiSessionNotice(session: session).session, session);
    });

    test('the stream notices carry their stream', () {
      final values = MidiStreamNotice(stream: stream, values: [1, 2]);
      expect(values.stream, stream);
      expect(values.values, equals([1, 2]));
      final error = MidiStreamErrorNotice(
        stream: stream,
        error: 'e',
        stack: 's',
      );
      expect((error.stream, error.error, error.stack), (stream, 'e', 's'));
      expect(MidiStreamDoneNotice(stream: stream).stream, stream);
    });

    test('MidiHostExitNotice tells that the MIDI isolate ended', () {
      final notices = <MidiHostNotice>[];
      final MidiNoticeSink sink = notices.add;
      const create = MidiHostExitNotice.new;
      sink(create());
      expect(notices.single, isA<MidiHostExitNotice>());
    });
  });
}
