// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:isolate';

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

void main() {
  group('MidiConnector', () {
    group('MidiConnector()', () {
      test('describes a host in the isolate of its proxies', () {
        const connector = MidiConnector(host: 7);
        expect(connector.host, 7);
        expect(connector.port, isNull);
        expect(connector.isolate, isNull);
        expect(connector.isLocal, isTrue);
      });

      test('describes a host in a MIDI isolate', () {
        final port = ReceivePort();
        addTearDown(port.close);
        final connector = MidiConnector(
          host: 7,
          port: port.sendPort,
          isolate: Isolate.current,
        );
        expect(connector.port, port.sendPort);
        expect(connector.isolate, Isolate.current);
        expect(connector.isLocal, isFalse);
      });
    });

    group('==, hashCode', () {
      test('compare the host', () {
        final port = ReceivePort();
        addTearDown(port.close);
        expect(
          MidiConnector(host: 7, port: port.sendPort),
          const MidiConnector(host: 7),
        );
        expect(
          const MidiConnector(host: 7).hashCode,
          const MidiConnector(host: 7).hashCode,
        );
        expect(
          const MidiConnector(host: 7) == const MidiConnector(host: 8),
          isFalse,
        );
      });
    });

    group('toString()', () {
      test('names the host and where it runs', () {
        final port = ReceivePort();
        addTearDown(port.close);
        expect(
          const MidiConnector(host: 7).toString(),
          'MidiConnector(host: 7, in-isolate)',
        );
        expect(
          MidiConnector(host: 7, port: port.sendPort).toString(),
          'MidiConnector(host: 7, isolate)',
        );
      });
    });
  });
}
