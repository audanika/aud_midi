// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/backend/midi_browse_lock_network.dart';
import 'package:test/test.dart';

void main() {
  late FakeMidiBackend fake;
  late MidiFakeNetworkBackend inner;
  late List<String> lock;
  late MidiBrowseLockNetwork network;
  const remote = MidiNetworkHostInfo(
    name: 'r',
    address: '10.0.0.9',
    port: 5004,
  );

  setUp(() {
    fake = FakeMidiBackend();
    inner = fake.network!;
    lock = [];
    network = MidiBrowseLockNetwork(
      network: inner,
      acquire: () => lock.add('acquire'),
      release: () => lock.add('release'),
    );
  });

  group('MidiBrowseLockNetwork', () {
    group('enable(), connect(), disconnect(), disable()', () {
      test('go to the wrapped session', () async {
        final changes = <MidiNetworkSessionInfo>[];
        final subscription = network.sessionChanges.listen(changes.add);
        final session = await network.enable(
          name: 'n',
          port: 5010,
          policy: MidiNetworkConnectionPolicy.specificPeers,
        );
        expect((session.localName, session.port), ('n', 5010));
        expect(
          network.session.connectionPolicy,
          MidiNetworkConnectionPolicy.specificPeers,
        );
        final connection = await network.connect(remote);
        expect(connection.host, remote);
        await network.disconnect(remote);
        await network.disable();
        expect(network.session.enabled, isFalse);
        await Future<void>.delayed(Duration.zero);
        expect(changes, hasLength(4));
        await subscription.cancel();
        expect(lock, isEmpty);
      });
    });

    group('browse()', () {
      test('holds the lock while browsers listen', () async {
        inner.addHost(remote);
        final first = <List<MidiNetworkHostInfo>>[];
        final a = network.browse().listen(first.add);
        final b = network.browse().listen((_) {});
        await Future<void>.delayed(Duration.zero);
        expect(first, [
          [remote],
        ]);
        expect(network.browsers, 2);
        expect(lock, ['acquire']);
        await a.cancel();
        expect(lock, ['acquire']);
        await b.cancel();
        expect(lock, ['acquire', 'release']);
        expect(network.browsers, 0);
      });

      test('reports a lock that cannot be taken and browses on', () async {
        network = MidiBrowseLockNetwork(
          network: inner,
          acquire: () =>
              throw const MidiPermissionDenied(MidiPermission.localNetwork),
          release: () => lock.add('release'),
        );
        final errors = <Object>[];
        final hosts = <List<MidiNetworkHostInfo>>[];
        final subscription = network.browse().listen(
          hosts.add,
          onError: errors.add,
        );
        await Future<void>.delayed(Duration.zero);
        expect(errors.single, isA<MidiPermissionDenied>());
        expect(hosts, [<MidiNetworkHostInfo>[]]);
        await subscription.cancel();
        expect(lock, ['release']);
      });
    });

    group('network, acquire, release', () {
      test('keep the given values', () {
        expect(network.network, same(inner));
        network.acquire();
        network.release();
        expect(lock, ['acquire', 'release']);
      });
    });
  });
}
