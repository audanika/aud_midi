// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkConnectionFailed', () {
    final connection = MidiNetworkConnectionInfo(
      host: const MidiNetworkHostInfo(
        name: 'Studio',
        address: '10.0.0.2',
        port: 5004,
      ),
      state: MidiNetworkConnectionState.failed,
    );

    group('MidiNetworkConnectionFailed()', () {
      test('keeps the failed connection', () {
        final error = MidiNetworkConnectionFailed(connection);
        expect(error.connection, same(connection));
        expect(error, isA<Exception>());
      });
    });

    group('toString()', () {
      test('names the host', () {
        expect(
          MidiNetworkConnectionFailed(connection).toString(),
          'MidiNetworkConnectionFailed: Studio at 10.0.0.2:5004 did not '
          'accept the connection',
        );
      });
    });
  });
}
