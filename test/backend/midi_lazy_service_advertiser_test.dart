// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/backend/midi_lazy_service_advertiser.dart';
import 'package:test/test.dart';

/// Records the registrations.
final class _Advertiser implements MidiServiceAdvertiser {
  final registered = <String>[];

  @override
  Future<MidiServiceRegistration> register({
    required String name,
    required String type,
    required int port,
    Map<String, String> txt = const {},
  }) async {
    registered.add('$name $type $port $txt');
    return _Registration(name);
  }
}

final class _Registration implements MidiServiceRegistration {
  _Registration(this.name);

  @override
  final String name;

  @override
  Future<void> unregister() async {}
}

void main() {
  group('MidiLazyServiceAdvertiser', () {
    group('register()', () {
      test('creates the real advertiser once, at the first call', () async {
        var created = 0;
        final real = _Advertiser();
        final lazy = MidiLazyServiceAdvertiser(() {
          created++;
          return real;
        });
        expect(lazy.isCreated, isFalse);
        expect(created, 0);
        final first = await lazy.register(
          name: 'a',
          type: '_apple-midi._udp',
          port: 5004,
          txt: const {'k': 'v'},
        );
        await lazy.register(name: 'b', type: '_midi2._udp', port: 5506);
        expect(lazy.isCreated, isTrue);
        expect(created, 1);
        expect(first.name, 'a');
        expect(real.registered, [
          'a _apple-midi._udp 5004 {k: v}',
          'b _midi2._udp 5506 {}',
        ]);
        await first.unregister();
      });
    });
  });
}
