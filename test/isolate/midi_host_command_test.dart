// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host_command.dart';
import 'package:aud_midi/src/isolate/midi_host_notice.dart';
import 'package:test/test.dart';

Object? _backendName(MidiBackend backend) => backend.name;

void main() {
  group('MidiHostCommand', () {
    var proxy = 3;
    var request = 4;
    const port = MidiPortId('fake:out');
    const host = MidiNetworkHostInfo(name: 'h', address: '1.2.3.4', port: 5004);
    final notices = <MidiHostNotice>[];
    const message = MidiNoteOn(channel: 0, note: 60, velocity: 1);
    final packet = MidiBytesPacket(
      bytes: MidiBytes([0xF8]),
      time: MidiTime.zero,
    );
    final spec = MidiVirtualPortSpec(name: 'v', direction: MidiDirection.input);

    test('MidiHelloCommand carries the sink of the proxy', () {
      final hello = MidiHelloCommand(request: request, sink: notices.add);
      expect((hello.proxy, hello.request), (0, request));
      hello.sink(const MidiHostExitNotice());
      expect(notices, [isA<MidiHostExitNotice>()]);
    });

    test('MidiGoodbyeCommand names the proxy', () {
      final goodbye = MidiGoodbyeCommand(proxy: proxy, request: request);
      expect((goodbye.proxy, goodbye.request), (proxy, request));
      expect(goodbye, isNot(isA<MidiHostRequest>()));
    });

    test('the input and stream commands carry their stream', () {
      final open = MidiOpenInputCommand(
        proxy: proxy,
        request: request,
        stream: 5,
        port: port,
        raw: true,
        options: const MidiInputOptions(queueCapacity: 2),
      );
      expect(
        (open.stream, open.port, open.raw, open.options),
        (5, port, true, const MidiInputOptions(queueCapacity: 2)),
      );
      final scan = MidiScanCommand(
        proxy: proxy,
        request: request,
        stream: 6,
        timeout: const Duration(seconds: 1),
      );
      expect((scan.stream, scan.timeout), (6, const Duration(seconds: 1)));
      expect(
        MidiBrowseCommand(proxy: proxy, request: request, stream: 7).stream,
        7,
      );
      expect(
        MidiCancelStreamCommand(
          proxy: proxy,
          request: request,
          stream: 8,
        ).stream,
        8,
      );
    });

    test('the output commands carry their port and payload', () {
      final send = MidiSendCommand(
        proxy: proxy,
        request: request,
        port: port,
        messages: [message],
        at: const MidiTime(9),
        group: 2,
      );
      expect((send.port, send.at, send.group), (port, const MidiTime(9), 2));
      expect(send.messages, equals([message]));
      final sendPacket = MidiSendPacketCommand(
        proxy: proxy,
        request: request,
        port: port,
        packet: packet,
      );
      expect((sendPacket.port, sendPacket.packet), (port, packet));
      expect(
        MidiCancelPendingCommand(
          proxy: proxy,
          request: request,
          port: port,
        ).port,
        port,
      );
      final panic = MidiOutputPanicCommand(
        proxy: proxy,
        request: request,
        port: port,
        panic: const MidiPanic(channels: [1]),
      );
      expect((panic.port, panic.panic), (port, const MidiPanic(channels: [1])));
      expect(
        MidiCloseOutputCommand(proxy: proxy, request: request, port: port).port,
        port,
      );
    });

    test('the engine commands carry their payload', () {
      expect(
        MidiPanicCommand(
          proxy: proxy,
          request: request,
          panic: const MidiPanic(),
        ).panic,
        const MidiPanic(),
      );
      expect(
        MidiDiagnosticsCommand(proxy: proxy, request: request),
        isA<MidiHostRequest>(),
      );
      final withBackend = MidiWithBackendCommand(
        proxy: proxy,
        request: request,
        action: _backendName,
      );
      expect(withBackend.action(FakeMidiBackend()), 'fake');
      expect(
        MidiCreateVirtualPortCommand(
          proxy: proxy,
          request: request,
          spec: spec,
        ).spec,
        spec,
      );
      expect(
        MidiRemoveVirtualPortCommand(
          proxy: proxy,
          request: request,
          port: port,
        ).port,
        port,
      );
    });

    test('the Bluetooth commands carry their peripheral', () {
      expect(
        MidiStopScanCommand(proxy: proxy, request: request),
        isA<MidiHostRequest>(),
      );
      final connect = MidiConnectPeripheralCommand(
        proxy: proxy,
        request: request,
        peripheral: 'p',
        timeout: const Duration(seconds: 2),
      );
      expect(
        (connect.peripheral, connect.timeout),
        ('p', const Duration(seconds: 2)),
      );
      expect(
        MidiDisconnectPeripheralCommand(
          proxy: proxy,
          request: request,
          peripheral: 'p',
        ).peripheral,
        'p',
      );
    });

    test('the network commands carry their session and host', () {
      final enable = MidiEnableNetworkCommand(
        proxy: proxy,
        request: request,
        name: 'n',
        policy: MidiNetworkConnectionPolicy.contacts,
        port: 5006,
      );
      expect(
        (enable.name, enable.policy, enable.port),
        ('n', MidiNetworkConnectionPolicy.contacts, 5006),
      );
      expect(
        MidiDisableNetworkCommand(proxy: proxy, request: request),
        isA<MidiHostRequest>(),
      );
      expect(
        MidiConnectHostCommand(proxy: proxy, request: request, host: host).host,
        host,
      );
      expect(
        MidiDisconnectHostCommand(
          proxy: proxy,
          request: request,
          host: host,
        ).host,
        host,
      );
    });
  });
}
