// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

void main() {
  group('MidiRemoteError', () {
    group('MidiRemoteError()', () {
      test('keeps the type and the text of the original', () {
        const error = MidiRemoteError(type: 'Oops', message: 'went wrong');
        expect(error.type, 'Oops');
        expect(error.message, 'went wrong');
        expect(error, isA<Exception>());
      });
    });

    group('==, hashCode', () {
      test('compare type and message', () {
        const error = MidiRemoteError(type: 'A', message: 'b');
        expect(error, const MidiRemoteError(type: 'A', message: 'b'));
        expect(
          error.hashCode,
          const MidiRemoteError(type: 'A', message: 'b').hashCode,
        );
        expect(
          error == const MidiRemoteError(type: 'X', message: 'b'),
          isFalse,
        );
        expect(
          error == const MidiRemoteError(type: 'A', message: 'x'),
          isFalse,
        );
      });
    });

    group('toString()', () {
      test('names type and message', () {
        expect(
          const MidiRemoteError(type: 'A', message: 'b').toString(),
          'MidiRemoteError(A): b',
        );
      });
    });
  });
}
