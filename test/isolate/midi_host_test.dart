// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi/aud_midi.dart';
import 'package:aud_midi/src/isolate/midi_host.dart';
import 'package:aud_midi/src/isolate/midi_host_command.dart';
import 'package:aud_midi/src/isolate/midi_host_notice.dart';
import 'package:aud_midi/src/isolate/midi_host_snapshot.dart';
import 'package:test/test.dart';

// .............................................................................
/// A backend that delegates to a fake but lets the test change the
/// capabilities and replace the Bluetooth and network sub-APIs.
final class _Backend implements MidiBackend {
  _Backend(this.fake);

  final FakeMidiBackend fake;
  MidiCapabilities? capabilitiesOverride;
  MidiBluetoothBackend? bluetoothOverride;

  @override
  Future<void> start(MidiBackendHost host) => fake.start(host);

  @override
  Future<void> stop() => fake.stop();

  @override
  Future<void> openPort(MidiPortId port) => fake.openPort(port);

  @override
  Future<void> closePort(MidiPortId port) => fake.closePort(port);

  @override
  Future<void> send(MidiPortId port, MidiPacket packet) =>
      fake.send(port, packet);

  @override
  Future<void> cancelPending(MidiPortId port) => fake.cancelPending(port);

  @override
  String get name => fake.name;

  @override
  MidiCapabilities get capabilities =>
      capabilitiesOverride ?? fake.capabilities;

  @override
  List<MidiPortInfo> get ports => fake.ports;

  @override
  MidiVirtualPortsBackend? get virtualPorts => fake.virtualPorts;

  @override
  MidiBluetoothBackend? get bluetooth => bluetoothOverride ?? fake.bluetooth;

  @override
  MidiNetworkBackend? get network => fake.network;
}

/// A Bluetooth backend whose scans fail.
final class _FailingScan implements MidiBluetoothBackend {
  @override
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) =>
      Stream.error(const MidiPermissionDenied(MidiPermission.bluetooth));

  @override
  Future<void> stopScan() async {}

  @override
  Future<List<MidiPortInfo>> connect(
    String peripheralId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => const [];

  @override
  Future<void> disconnect(String peripheralId) async {}
}

/// An error that refuses to be sent.
final class _Poison {
  const _Poison();
}

void main() {
  late FakeMidiBackend fake;
  late _Backend backend;
  late MidiHost host;
  late List<MidiHostNotice> received;
  late Map<int, Completer<MidiHostNotice>> answers;
  late int proxy;
  var lastRequest = 0;
  late MidiPortInfo input;
  late MidiPortInfo output;

  void sink(MidiHostNotice notice) {
    switch (notice) {
      case MidiNoticeBatch(:final notices):
        notices.forEach(sink);
      case MidiReplyNotice(:final request) || MidiFailureNotice(:final request):
        received.add(notice);
        final answer = answers[request] ??= Completer();
        if (!answer.isCompleted) answer.complete(notice);
      default:
        received.add(notice);
    }
  }

  // Sends the command [command] builds and returns the answer's value.
  Future<Object?> ask(
    MidiHostCommand Function(int request) command, {
    MidiNoticeSink? via,
  }) async {
    final request = ++lastRequest;
    host.handle(command(request));
    final answer = await (answers[request] ??= Completer()).future;
    return switch (answer) {
      MidiReplyNotice(:final value) => value,
      MidiFailureNotice(:final error) => throw error,
      _ => throw StateError('No answer'),
    };
  }

  Future<MidiHostSnapshot> hello([MidiNoticeSink? to]) async =>
      await ask(
            (request) => MidiHelloCommand(request: request, sink: to ?? sink),
          )
          as MidiHostSnapshot;

  // Lets the microtasks and timers of a few turns run; notices leave in
  // a timer after the turn that posted them.
  Future<void> pump() async {
    for (var turn = 0; turn < 3; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<T> receivedOf<T>() => [...received.whereType<T>()];

  List<Object?> streamValues(int stream) => [
    for (final notice in received)
      if (notice is MidiStreamNotice && notice.stream == stream)
        ...notice.values,
  ];

  Future<void> start({FakeMidiBackend? with_}) async {
    fake = with_ ?? FakeMidiBackend();
    input = fake.addPort(fake.portInfo('in', direction: MidiDirection.input));
    output = fake.addPort(
      fake.portInfo('out', direction: MidiDirection.output),
    );
    fake.connectLoopback(output.id, input.id);
    backend = _Backend(fake);
    host = MidiHost(backend: backend, id: 42);
    await host.start();
    proxy = (await hello()).proxy;
  }

  setUp(() async {
    received = [];
    answers = {};
    lastRequest = 0;
    await start();
  });

  tearDown(() async {
    if (!host.isClosed && host.proxyCount > 0) {
      fake.failWith();
      for (var id = 1; id <= proxy + 4; id++) {
        host.handle(MidiGoodbyeCommand(proxy: id, request: 1000 + id));
      }
      await host.done;
    }
  });

  group('MidiHost', () {
    group('MidiHost()', () {
      test('takes the given id or a random one', () {
        expect(host.id, 42);
        final random = MidiHost(backend: FakeMidiBackend()).id;
        expect(random, inInclusiveRange(0, 0xFFFFFFFF));
        expect(host.engine.backend, same(backend));
      });
    });

    group('start()', () {
      test('opens the engine', () {
        expect(host.engine.isOpen, isTrue);
        expect(host.isClosed, isFalse);
        expect(host.proxyCount, 1);
      });

      test('closes the host when the backend fails to start', () async {
        final failing = FakeMidiBackend()
          ..failWith(start: const MidiPermissionDenied(MidiPermission.midi));
        final other = MidiHost(backend: failing);
        await expectLater(
          other.start(),
          throwsA(
            isA<MidiPermissionDenied>().having(
              (e) => e.permission,
              'permission',
              MidiPermission.midi,
            ),
          ),
        );
        expect(other.isClosed, isTrue);
        await other.done;
      });
    });

    group('handle(MidiHelloCommand)', () {
      test('answers with the state of the host', () async {
        final snapshot = await hello();
        expect(snapshot.proxy, proxy + 1);
        expect(snapshot.backend, 'fake');
        expect(snapshot.capabilities, fake.capabilities);
        expect(snapshot.ports, equals([input, output]));
        expect(snapshot.hasVirtualPorts, isTrue);
        expect(snapshot.hasBluetooth, isTrue);
        expect(snapshot.session, fake.network!.session);
        expect(host.proxyCount, 2);
      });

      test('describes a backend without sub-APIs', () async {
        await host.engine.close();
        await start(
          with_: FakeMidiBackend(
            hasVirtualPorts: false,
            hasBluetooth: false,
            hasNetwork: false,
          ),
        );
        final snapshot = await hello();
        expect(snapshot.hasVirtualPorts, isFalse);
        expect(snapshot.hasBluetooth, isFalse);
        expect(snapshot.session, isNull);
      });

      test('hands the newest early diagnostics to the first proxy', () async {
        final early = FakeMidiBackend();
        final other = MidiHost(backend: early);
        await other.start();
        for (var i = 0; i <= MidiHost.earlyDiagnostics; i++) {
          early.reportDiagnostic(
            MidiDiagnostic(
              kind: MidiDiagnosticKind.nativeError,
              count: i,
              cause: 'early',
              time: MidiTime.zero,
            ),
          );
        }
        await pump();
        final notices = <MidiHostNotice>[];
        void collect(MidiHostNotice notice) => notice is MidiNoticeBatch
            ? notice.notices.forEach(collect)
            : notices.add(notice);
        other.handle(MidiHelloCommand(request: 1, sink: collect));
        await pump();
        expect(notices.first, isA<MidiReplyNotice>());
        final diagnostics = [
          for (final notice in notices.whereType<MidiDiagnosticsNotice>())
            ...notice.diagnostics,
        ];
        expect(diagnostics.map((d) => d.count), [
          for (var i = 1; i <= MidiHost.earlyDiagnostics; i++) i,
        ]);
        other.handle(const MidiGoodbyeCommand(proxy: 1, request: 2));
        await other.done;
      });

      test('refuses proxies once the host shut down', () async {
        host.handle(MidiGoodbyeCommand(proxy: proxy, request: 99));
        await host.done;
        await expectLater(
          hello(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The MIDI host shuts down',
            ),
          ),
        );
      });
    });

    group('handle(MidiGoodbyeCommand)', () {
      test('keeps the host for the other proxies', () async {
        final second = (await hello()).proxy;
        expect(
          await ask(
            (request) => MidiGoodbyeCommand(proxy: second, request: request),
          ),
          isFalse,
        );
        expect(host.proxyCount, 1);
        expect(host.isClosed, isFalse);
      });

      test('shuts the host down after the last proxy', () async {
        expect(
          await ask(
            (request) => MidiGoodbyeCommand(proxy: proxy, request: request),
          ),
          isTrue,
        );
        await host.done;
        expect(host.isClosed, isTrue);
        expect(host.engine.isClosed, isTrue);
        expect(fake.isStarted, isFalse);
      });

      test('reports a backend that fails to stop', () async {
        fake.failWith(stop: const MidiNativeError(api: 'stop', code: 1));
        await expectLater(
          ask((request) => MidiGoodbyeCommand(proxy: proxy, request: request)),
          throwsA(isA<MidiNativeError>().having((e) => e.api, 'api', 'stop')),
        );
        await host.done;
      });

      test('closes the streams and outputs of the proxy', () async {
        await ask(
          (request) => MidiOpenInputCommand(
            proxy: proxy,
            request: request,
            stream: 1,
            port: input.id,
            raw: false,
          ),
        );
        final second = (await hello()).proxy;
        await ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: const [MidiTimingClock()],
          ),
        );
        expect(fake.openPorts, {input.id, output.id});
        await ask(
          (request) => MidiGoodbyeCommand(proxy: proxy, request: request),
        );
        expect(fake.openPorts, isEmpty);
        expect(host.proxyCount, 1);
        await ask(
          (request) => MidiGoodbyeCommand(proxy: second, request: request),
        );
      });

      test('ignores unknown and leaving proxies', () async {
        host
          ..handle(const MidiGoodbyeCommand(proxy: 77, request: 1))
          ..handle(MidiGoodbyeCommand(proxy: proxy, request: 2))
          ..handle(MidiGoodbyeCommand(proxy: proxy, request: 3))
          ..handle(
            MidiPanicCommand(
              proxy: proxy,
              request: 4,
              panic: const MidiPanic(),
            ),
          )
          ..handle(
            const MidiPanicCommand(proxy: 77, request: 5, panic: MidiPanic()),
          );
        await host.done;
        await pump();
        expect(receivedOf<MidiReplyNotice>().map((reply) => reply.request), [
          1,
          2,
        ]);
      });
    });

    group('handle(MidiOpenInputCommand)', () {
      test('forwards the events and packets of the input', () async {
        for (final raw in [false, true]) {
          await ask(
            (request) => MidiOpenInputCommand(
              proxy: proxy,
              request: request,
              stream: raw ? 2 : 1,
              port: input.id,
              raw: raw,
              options: raw ? null : const MidiInputOptions(),
            ),
          );
        }
        final packet = MidiBytesPacket(
          bytes: MidiBytes([0x90, 60, 100, 0x80, 60, 0]),
          time: const MidiTime(5),
        );
        fake.inject(input.id, packet);
        await pump();
        await pump();
        expect(streamValues(1), [
          MidiEvent(
            message: const MidiNoteOn(channel: 0, note: 60, velocity: 100),
            time: const MidiTime(5),
            port: input.id,
            group: 0,
          ),
          MidiEvent(
            message: const MidiNoteOff(channel: 0, note: 60, velocity: 0),
            time: const MidiTime(5),
            port: input.id,
            group: 0,
          ),
        ]);
        expect(streamValues(2), [packet]);
        expect(
          received.whereType<MidiStreamNotice>().where((n) => n.stream == 1),
          hasLength(1),
          reason: 'the events of one turn leave in one notice',
        );
      });

      test('ends the stream when the port disappears', () async {
        await ask(
          (request) => MidiOpenInputCommand(
            proxy: proxy,
            request: request,
            stream: 1,
            port: input.id,
            raw: false,
          ),
        );
        fake.removePort(input.id);
        await pump();
        await pump();
        expect(receivedOf<MidiStreamDoneNotice>().map((done) => done.stream), [
          1,
        ]);
      });

      test('fails for an unknown port', () async {
        await expectLater(
          ask(
            (request) => MidiOpenInputCommand(
              proxy: proxy,
              request: request,
              stream: 1,
              port: const MidiPortId('fake:none'),
              raw: false,
            ),
          ),
          throwsA(isA<MidiPortGone>()),
        );
        await ask(
          (request) => MidiCancelStreamCommand(
            proxy: proxy,
            request: request,
            stream: 1,
          ),
        );
      });

      test('closes the session of a stream cancelled while opening', () async {
        fake.holdCalls();
        final opened = ask(
          (request) => MidiOpenInputCommand(
            proxy: proxy,
            request: request,
            stream: 1,
            port: input.id,
            raw: false,
          ),
        );
        final cancelled = ask(
          (request) => MidiCancelStreamCommand(
            proxy: proxy,
            request: request,
            stream: 1,
          ),
        );
        await cancelled;
        fake.releaseCalls();
        await opened;
        await pump();
        expect(fake.openPorts, isEmpty);
        expect(fake.calls, [
          'start',
          'openPort ${input.id}',
          'closePort ${input.id}',
        ]);
      });
    });

    group('handle(MidiScanCommand)', () {
      test('forwards the peripherals until the scan stops', () async {
        final peripheral = MidiBlePeripheralInfo(id: 'p1', name: 'Keys');
        fake.bluetooth!.addPeripheral(peripheral);
        await ask(
          (request) =>
              MidiScanCommand(proxy: proxy, request: request, stream: 3),
        );
        await pump();
        expect(streamValues(3), [peripheral]);
        await ask(
          (request) => MidiStopScanCommand(proxy: proxy, request: request),
        );
        await pump();
        expect(receivedOf<MidiStreamDoneNotice>().map((done) => done.stream), [
          3,
        ]);
      });

      test('forwards the errors of a scan', () async {
        backend.bluetoothOverride = _FailingScan();
        await ask(
          (request) => MidiScanCommand(
            proxy: proxy,
            request: request,
            stream: 3,
            timeout: const Duration(seconds: 1),
          ),
        );
        await pump();
        final error = receivedOf<MidiStreamErrorNotice>().single;
        expect(error.stream, 3);
        expect(error.error, isA<MidiPermissionDenied>());
        expect(error.stack, isA<String>());
      });

      test('fails without Bluetooth', () async {
        await host.engine.close();
        await start(with_: FakeMidiBackend(hasBluetooth: false));
        await expectLater(
          ask(
            (request) =>
                MidiScanCommand(proxy: proxy, request: request, stream: 3),
          ),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'Bluetooth LE MIDI',
            ),
          ),
        );
      });
    });

    group('handle(MidiCancelStreamCommand)', () {
      test('ends a scan', () async {
        await ask(
          (request) =>
              MidiScanCommand(proxy: proxy, request: request, stream: 3),
        );
        expect(fake.bluetooth!.isScanning, isTrue);
        await ask(
          (request) => MidiCancelStreamCommand(
            proxy: proxy,
            request: request,
            stream: 3,
          ),
        );
        expect(fake.bluetooth!.isScanning, isFalse);
        expect(receivedOf<MidiStreamDoneNotice>(), isEmpty);
      });
    });

    group('handle(MidiBrowseCommand)', () {
      test('forwards the hosts', () async {
        const remote = MidiNetworkHostInfo(
          name: 'r',
          address: '10.0.0.2',
          port: 5004,
        );
        await ask(
          (request) =>
              MidiBrowseCommand(proxy: proxy, request: request, stream: 4),
        );
        fake.network!.addHost(remote);
        await pump();
        expect(streamValues(4), [
          <MidiNetworkHostInfo>[],
          [remote],
        ]);
      });

      test('fails without a network session', () async {
        await host.engine.close();
        await start(with_: FakeMidiBackend(hasNetwork: false));
        await expectLater(
          ask(
            (request) =>
                MidiBrowseCommand(proxy: proxy, request: request, stream: 4),
          ),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'Network sessions',
            ),
          ),
        );
      });
    });

    group('handle(output commands)', () {
      test('opens the output once and sends in order', () async {
        fake.holdCalls();
        final first = ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: [const MidiNoteOn(channel: 0, note: 1, velocity: 1)],
          ),
        );
        final second = ask(
          (request) => MidiSendPacketCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            packet: MidiBytesPacket(
              bytes: MidiBytes([0x90, 2, 1]),
              time: MidiTime.zero,
            ),
          ),
        );
        await pump();
        fake.releaseCalls();
        await Future.wait([first, second]);
        await ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: [const MidiNoteOn(channel: 0, note: 3, velocity: 1)],
            group: 0,
          ),
        );
        expect(
          [
            for (final sent in fake.sent)
              (sent.packet as MidiBytesPacket).bytes,
          ],
          [
            MidiBytes([0x90, 1, 1]),
            MidiBytes([0x90, 2, 1]),
            MidiBytes([0x90, 3, 1]),
          ],
        );
        expect(
          fake.calls.where((call) => call.startsWith('openPort')),
          hasLength(1),
        );
      });

      test('cancels, silences and closes the output', () async {
        expect(
          await ask(
            (request) => MidiCancelPendingCommand(
              proxy: proxy,
              request: request,
              port: output.id,
            ),
          ),
          0,
        );
        await ask(
          (request) => MidiOutputPanicCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            panic: const MidiPanic(channels: [0], noteOffs: false),
          ),
        );
        expect(
          (fake.sent.last.packet as MidiBytesPacket).bytes,
          MidiBytes([0xB0, 120, 0, 0xB0, 121, 0, 0xB0, 123, 0]),
        );
        await ask(
          (request) => MidiCloseOutputCommand(
            proxy: proxy,
            request: request,
            port: output.id,
          ),
        );
        expect(fake.openPorts, isEmpty);
        await ask(
          (request) => MidiCloseOutputCommand(
            proxy: proxy,
            request: request,
            port: output.id,
          ),
        );
      });

      test('closes an output while it opens', () async {
        fake.holdCalls();
        final sent = ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: const [MidiStart()],
          ),
        );
        final closed = ask(
          (request) => MidiCloseOutputCommand(
            proxy: proxy,
            request: request,
            port: output.id,
          ),
        );
        await pump();
        fake.releaseCalls();
        await sent;
        await closed;
        expect(fake.openPorts, isEmpty);
      });

      test('forgets an output that failed to open', () async {
        fake.failWith(openPort: const MidiNativeError(api: 'open', code: 2));
        final sent = ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: const [MidiStart()],
          ),
        );
        final closed = ask(
          (request) => MidiCloseOutputCommand(
            proxy: proxy,
            request: request,
            port: output.id,
          ),
        );
        await expectLater(sent, throwsA(isA<MidiNativeError>()));
        await closed;
      });

      test('opens an output again after its port came back', () async {
        await ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: const [MidiStart()],
          ),
        );
        fake.removePort(output.id);
        await pump();
        await expectLater(
          ask(
            (request) => MidiSendCommand(
              proxy: proxy,
              request: request,
              port: output.id,
              messages: const [MidiStop()],
            ),
          ),
          throwsA(isA<MidiPortGone>()),
        );
        fake.addPort(output);
        await pump();
        await ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: const [MidiContinue()],
          ),
        );
        expect(
          (fake.sent.last.packet as MidiBytesPacket).bytes,
          MidiBytes([0xFB]),
        );
      });
    });

    group('handle(engine commands)', () {
      test('panics, counts and runs code with the backend', () async {
        await ask(
          (request) => MidiSendCommand(
            proxy: proxy,
            request: request,
            port: output.id,
            messages: const [MidiStart()],
          ),
        );
        await ask(
          (request) => MidiPanicCommand(
            proxy: proxy,
            request: request,
            panic: const MidiPanic(channels: [], noteOffs: false),
          ),
        );
        fake.reportDiagnostic(
          const MidiDiagnostic(
            kind: MidiDiagnosticKind.networkLoss,
            cause: 'lost',
            time: MidiTime.zero,
          ),
        );
        final snapshot =
            await ask(
                  (request) =>
                      MidiDiagnosticsCommand(proxy: proxy, request: request),
                )
                as MidiDiagnosticsSnapshot;
        expect(snapshot.count(MidiDiagnosticKind.networkLoss), 1);
        expect(
          await ask(
            (request) => MidiWithBackendCommand(
              proxy: proxy,
              request: request,
              action: (backend) => backend.name,
            ),
          ),
          'fake',
        );
        expect(
          receivedOf<MidiDiagnosticsNotice>().single.diagnostics.single.cause,
          'lost',
        );
      });

      test('creates and removes virtual ports', () async {
        final port =
            await ask(
                  (request) => MidiCreateVirtualPortCommand(
                    proxy: proxy,
                    request: request,
                    spec: MidiVirtualPortSpec(
                      name: 'v',
                      direction: MidiDirection.output,
                    ),
                  ),
                )
                as MidiPortInfo;
        expect(port.isOwn, isTrue);
        await ask(
          (request) => MidiRemoveVirtualPortCommand(
            proxy: proxy,
            request: request,
            port: port.id,
          ),
        );
        await pump();
        expect(
          [
            for (final notice in receivedOf<MidiPortsNotice>())
              for (final event in notice.events) event.runtimeType,
          ],
          [MidiPortAdded, MidiPortRemoved],
        );
      });

      test('connects and disconnects peripherals', () async {
        fake.bluetooth!.addPeripheral(MidiBlePeripheralInfo(id: 'p1'));
        final ports =
            await ask(
                  (request) => MidiConnectPeripheralCommand(
                    proxy: proxy,
                    request: request,
                    peripheral: 'p1',
                    timeout: const Duration(seconds: 1),
                  ),
                )
                as List<MidiPortInfo>;
        expect(ports.map((port) => port.direction), [
          MidiDirection.input,
          MidiDirection.output,
        ]);
        await ask(
          (request) => MidiDisconnectPeripheralCommand(
            proxy: proxy,
            request: request,
            peripheral: 'p1',
          ),
        );
        expect(
          fake.bluetooth!.peripherals.single.state,
          MidiBlePeripheralState.disconnected,
        );
      });

      test('runs the network session and forwards its changes', () async {
        const remote = MidiNetworkHostInfo(
          name: 'r',
          address: '10.0.0.2',
          port: 5004,
        );
        final session =
            await ask(
                  (request) => MidiEnableNetworkCommand(
                    proxy: proxy,
                    request: request,
                    name: 'Studio',
                    policy: MidiNetworkConnectionPolicy.anyone,
                    port: 5008,
                  ),
                )
                as MidiNetworkSessionInfo;
        expect((session.localName, session.port), ('Studio', 5008));
        final connection =
            await ask(
                  (request) => MidiConnectHostCommand(
                    proxy: proxy,
                    request: request,
                    host: remote,
                  ),
                )
                as MidiNetworkConnectionInfo;
        expect(connection.state, MidiNetworkConnectionState.connected);
        await ask(
          (request) => MidiDisconnectHostCommand(
            proxy: proxy,
            request: request,
            host: remote,
          ),
        );
        await ask(
          (request) =>
              MidiDisableNetworkCommand(proxy: proxy, request: request),
        );
        await pump();
        expect(
          receivedOf<MidiSessionNotice>().map(
            (notice) => notice.session.connections.length,
          ),
          [0, 1, 0, 0],
        );
        expect(receivedOf<MidiSessionNotice>().last.session.enabled, isFalse);
      });
    });

    group('forwarding', () {
      test('merges the port events of one turn', () async {
        fake
          ..addPort(fake.portInfo('a', direction: MidiDirection.input))
          ..addPort(fake.portInfo('b', direction: MidiDirection.input));
        await pump();
        await pump();
        expect(
          receivedOf<MidiPortsNotice>().single.events.map((e) => e.port.name),
          ['a', 'b'],
        );
      });

      test('tells when the capabilities change', () async {
        backend.capabilitiesOverride = MidiCapabilities(bleScan: true);
        fake.addPort(fake.portInfo('a', direction: MidiDirection.input));
        await pump();
        await pump();
        fake.addPort(fake.portInfo('b', direction: MidiDirection.input));
        await pump();
        await pump();
        expect(
          receivedOf<MidiCapabilitiesNotice>().single.capabilities,
          MidiCapabilities(bleScan: true),
        );
      });

      test('merges the diagnostics of one turn', () async {
        for (final cause in ['a', 'b']) {
          fake.reportDiagnostic(
            MidiDiagnostic(
              kind: MidiDiagnosticKind.nativeError,
              cause: cause,
              time: MidiTime.zero,
            ),
          );
        }
        await pump();
        await pump();
        expect(
          receivedOf<MidiDiagnosticsNotice>().single.diagnostics.map(
            (d) => d.cause,
          ),
          ['a', 'b'],
        );
      });
    });

    group('reportError(error, stack)', () {
      test('reports the error as a diagnostic', () async {
        host.reportError(StateError('boom'), StackTrace.current);
        await pump();
        final diagnostic =
            receivedOf<MidiDiagnosticsNotice>().single.diagnostics.single;
        expect(diagnostic.kind, MidiDiagnosticKind.nativeError);
        expect(
          diagnostic.cause,
          'Uncaught error in the MIDI isolate: Bad state: boom',
        );
      });
    });

    group('notices that cannot leave', () {
      late List<MidiHostNotice> picked;
      late int picky;

      bool isPoison(MidiHostNotice notice) => switch (notice) {
        MidiNoticeBatch(:final notices) => notices.any(isPoison),
        MidiReplyNotice(:final value) => value is _Poison,
        MidiFailureNotice(:final error) => error is _Poison,
        MidiPortsNotice(:final events) => events.any(
          (event) => event.port.name == 'poison',
        ),
        _ => false,
      };

      void pick(MidiHostNotice notice) {
        if (isPoison(notice)) throw ArgumentError('cannot leave');
        picked.add(notice);
        sink(notice);
      }

      setUp(() async {
        picked = [];
        picky = (await hello(pick)).proxy;
      });

      test('replace a result by a remote error', () async {
        host.handle(
          MidiWithBackendCommand(
            proxy: picky,
            request: 1,
            action: (_) => const _Poison(),
          ),
        );
        await pump();
        await pump();
        final failure = picked.whereType<MidiFailureNotice>().single;
        expect(failure.request, 1);
        expect(
          failure.error,
          isA<MidiRemoteError>()
              .having((e) => e.type, 'type', '_Poison')
              .having(
                (e) => e.message,
                'message',
                startsWith('The result cannot leave the MIDI isolate: '),
              ),
        );
      });

      test('replace an error by a remote error', () async {
        host.handle(
          MidiWithBackendCommand(
            proxy: picky,
            request: 1,
            action: (_) => throw const _Poison(),
          ),
        );
        await pump();
        await pump();
        final failure = picked.whereType<MidiFailureNotice>().single;
        expect(
          failure.error,
          isA<MidiRemoteError>().having((e) => e.type, 'type', '_Poison'),
        );
        expect(failure.stack, isNotEmpty);
      });

      test('replace other notices by a diagnostic', () async {
        fake
          ..addPort(fake.portInfo('poison', direction: MidiDirection.input))
          ..reportDiagnostic(
            const MidiDiagnostic(
              kind: MidiDiagnosticKind.nativeError,
              cause: 'after',
              time: MidiTime.zero,
            ),
          );
        await pump();
        await pump();
        final causes = [
          for (final notice in picked.whereType<MidiDiagnosticsNotice>())
            for (final diagnostic in notice.diagnostics) diagnostic.cause,
        ];
        expect(causes, [
          startsWith('A MidiPortsNotice could not leave the MIDI isolate: '),
          'after',
        ]);
      });
    });
  });
}
