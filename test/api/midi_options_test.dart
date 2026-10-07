// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

MidiBackend _fake() => FakeMidiBackend();

void main() {
  group('MidiOptions', () {
    group('MidiOptions()', () {
      test('selects the platform backend and the host defaults', () {
        const options = MidiOptions();
        expect(options.backend, isNull);
        expect(options.engine, isNull);
        expect(options.inIsolate, isFalse);
        expect(options.clientName, 'aud_midi');
        expect(options.sysEx, isFalse);
        expect(options.networkProtocol, MidiNetworkProtocol.appleMidi);
      });
    });

    group('engineFor(inMidiIsolate)', () {
      test('keeps a lookahead of 100 ms in a MIDI isolate', () {
        expect(
          const MidiOptions().engineFor(inMidiIsolate: true),
          const MidiEngineOptions(lookahead: Duration(milliseconds: 100)),
        );
        expect(MidiOptions.defaultLookahead, const Duration(milliseconds: 100));
      });

      test('hands packets over at once in the isolate of the app', () {
        expect(
          const MidiOptions().engineFor(inMidiIsolate: false),
          const MidiEngineOptions(),
        );
      });

      test('returns given settings unchanged', () {
        const engine = MidiEngineOptions(lateThreshold: Duration(seconds: 1));
        for (final inMidiIsolate in [true, false]) {
          expect(
            const MidiOptions(
              engine: engine,
            ).engineFor(inMidiIsolate: inMidiIsolate),
            same(engine),
          );
        }
      });
    });

    group('copyWith()', () {
      test('replaces the given fields', () {
        const engine = MidiEngineOptions(flushDataEntryMsb: true);
        final copy = const MidiOptions().copyWith(
          backend: _fake,
          engine: engine,
          inIsolate: true,
          clientName: 'app',
          sysEx: true,
          networkProtocol: MidiNetworkProtocol.networkMidi2,
        );
        expect(
          copy,
          const MidiOptions(
            backend: _fake,
            engine: engine,
            inIsolate: true,
            clientName: 'app',
            sysEx: true,
            networkProtocol: MidiNetworkProtocol.networkMidi2,
          ),
        );
        expect(copy.copyWith(), copy);
      });

      test('clears the backend and the engine', () {
        const options = MidiOptions(
          backend: _fake,
          engine: MidiEngineOptions(),
        );
        final cleared = options.copyWith(
          clearBackend: true,
          backend: _fake,
          clearEngine: true,
          engine: const MidiEngineOptions(),
        );
        expect(cleared.backend, isNull);
        expect(cleared.engine, isNull);
      });
    });

    group('==, hashCode', () {
      test('compare all fields', () {
        const options = MidiOptions(backend: _fake);
        expect(options, const MidiOptions(backend: _fake));
        expect(options.hashCode, const MidiOptions(backend: _fake).hashCode);
        final others = [
          const MidiOptions(),
          const MidiOptions(backend: _fake, engine: MidiEngineOptions()),
          const MidiOptions(backend: _fake, inIsolate: true),
          const MidiOptions(backend: _fake, clientName: 'other'),
          const MidiOptions(backend: _fake, sysEx: true),
          const MidiOptions(
            backend: _fake,
            networkProtocol: MidiNetworkProtocol.networkMidi2,
          ),
        ];
        for (final other in others) {
          expect(options == other, isFalse, reason: '$other');
        }
      });
    });

    group('toString()', () {
      test('names the fields', () {
        expect(
          const MidiOptions().toString(),
          'MidiOptions(backend: platform, engine: null, inIsolate: false, '
          "clientName: 'aud_midi', sysEx: false, networkProtocol: appleMidi)",
        );
        expect(
          const MidiOptions(backend: _fake).toString(),
          startsWith('MidiOptions(backend: custom, '),
        );
      });
    });
  });
}
