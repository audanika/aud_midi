// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

const _remote = MidiNetworkHostInfo(
  name: 'Studio',
  address: '10.0.0.2',
  port: 5004,
  source: MidiNetworkHostSource.bonjour,
);

/// A network session whose connections to port 9 fail.
final class _Refusing implements MidiNetworkBackend {
  _Refusing(this.inner);

  final MidiNetworkBackend inner;

  @override
  Future<MidiNetworkSessionInfo> enable({
    required String name,
    int? port,
    MidiNetworkConnectionPolicy policy = MidiNetworkConnectionPolicy.anyone,
  }) => inner.enable(name: name, port: port, policy: policy);

  @override
  Future<void> disable() => inner.disable();

  @override
  Future<MidiNetworkConnectionInfo> connect(MidiNetworkHostInfo host) async =>
      host.port == 9
      ? MidiNetworkConnectionInfo(
          host: host,
          state: MidiNetworkConnectionState.failed,
        )
      : inner.connect(host);

  @override
  Future<void> disconnect(MidiNetworkHostInfo host) => inner.disconnect(host);

  @override
  Stream<List<MidiNetworkHostInfo>> browse() => inner.browse();

  @override
  MidiNetworkSessionInfo get session => inner.session;

  @override
  Stream<MidiNetworkSessionInfo> get sessionChanges => inner.sessionChanges;
}

MidiBackend _backend() {
  final fake = FakeMidiBackend();
  fake.network!.addHost(_remote);
  return MidiCompositeBackend(
    backends: [fake],
    network: _Refusing(fake.network!),
  );
}

void main() {
  late Midi midi;

  for (final inIsolate in [false, true]) {
    final mode = inIsolate ? 'in-isolate' : 'MIDI isolate';

    group('MidiNetwork ($mode)', () {
      setUp(() async {
        midi = await Midi.open(
          options: MidiOptions(backend: _backend, inIsolate: inIsolate),
        );
      });

      tearDown(() async => midi.close());

      group('enable(), disable(), session, sessionChanges', () {
        test('run the session and report its changes', () async {
          final network = midi.network!;
          expect(network.session.enabled, isFalse);
          final changes = <MidiNetworkSessionInfo>[];
          final subscription = network.sessionChanges.listen(changes.add);
          final session = await network.enable(
            name: 'Desk',
            port: 5010,
            policy: MidiNetworkConnectionPolicy.contacts,
          );
          expect((session.localName, session.port), ('Desk', 5010));
          expect(network.session, session);
          await network.disable();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(changes.map((change) => change.enabled), [true, false]);
          expect(network.session.enabled, isFalse);
          await subscription.cancel();
        });
      });

      group('connect(host, port), connectTo(host), disconnect(host)', () {
        test('connect sessions and add their ports', () async {
          final network = midi.network!;
          await network.enable(name: 'Desk');
          final manual = await network.connect('10.0.0.3', 5004);
          expect(manual.host.address, '10.0.0.3');
          expect(manual.host.source, MidiNetworkHostSource.manual);
          final found = await network.connectTo(_remote);
          expect(found.state, MidiNetworkConnectionState.connected);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(midi.inputs.map((input) => input.info.name), [
            '10.0.0.3',
            'Studio',
          ]);
          await network.disconnect(_remote);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(midi.inputs.map((input) => input.info.name), ['10.0.0.3']);
        });

        test('fail for a session that refuses', () async {
          await midi.network!.enable(name: 'Desk');
          await expectLater(
            midi.network!.connect('10.0.0.9', 9),
            throwsA(
              isA<MidiNetworkConnectionFailed>().having(
                (e) => e.connection.host.port,
                'port',
                9,
              ),
            ),
          );
        });
      });

      group('browse()', () {
        test('reports the hosts in the network', () async {
          final hosts = await midi.network!.browse().first;
          expect(hosts, [_remote]);
        });
      });
    });
  }
}
