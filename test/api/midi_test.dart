// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:isolate';

import 'package:aud_midi/aud_midi.dart';
import 'package:test/test.dart';

// .............................................................................
// Backends, created inside the MIDI isolate by these factories.

/// A backend that delegates to a fake with an input and an output that are
/// looped back, and whose capabilities and Bluetooth the tests change.
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

/// A Bluetooth backend whose scans fail in two ways.
final class _BrokenScan implements MidiBluetoothBackend {
  @override
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) => timeout == null
      ? Stream.error(const MidiPermissionDenied(MidiPermission.bluetooth))
      : throw const MidiUnsupported('Scanning with a timeout');

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

MidiBackend _backend() {
  final fake = FakeMidiBackend();
  final input = fake.addPort(
    fake.portInfo(
      'in',
      direction: MidiDirection.input,
      deviceId: const MidiDeviceId('fake:dev'),
      serialNumber: 's1',
    ),
  );
  final output = fake.addPort(
    fake.portInfo('out', direction: MidiDirection.output),
  );
  fake.connectLoopback(output.id, input.id);
  return _Backend(fake);
}

MidiBackend _bare() => FakeMidiBackend(
  hasVirtualPorts: false,
  hasBluetooth: false,
  hasNetwork: false,
);

MidiBackend _refusing() =>
    FakeMidiBackend()
      ..failWith(start: const MidiPermissionDenied(MidiPermission.midi));

MidiBackend _stopFailing() =>
    FakeMidiBackend()
      ..failWith(stop: const MidiNativeError(api: 'stop', code: 7));

// .............................................................................
// Actions that run inside the MIDI isolate.

FakeMidiBackend _fakeOf(MidiBackend backend) => (backend as _Backend).fake;

Future<void> _addInput(Midi midi, String name) => midi.withBackend((backend) {
  final fake = _fakeOf(backend);
  fake.addPort(
    fake.portInfo(name, direction: MidiDirection.input, serialNumber: 's1'),
  );
  return null;
});

Future<void> _rename(Midi midi, MidiPortId id, String name) => midi.withBackend(
  (backend) => _fakeOf(
    backend,
  ).changePort(_fakeOf(backend).port(id)!.copyWith(name: name)),
);

Future<void> _remove(Midi midi, MidiPortId id) =>
    midi.withBackend((backend) => _fakeOf(backend).removePort(id));

Future<void> _changeCapabilities(Midi midi) => midi.withBackend((backend) {
  (backend as _Backend).capabilitiesOverride = MidiCapabilities(ump: true);
  backend.fake.addPort(
    backend.fake.portInfo('trigger', direction: MidiDirection.input),
  );
  return null;
});

Future<void> _breakScans(Midi midi) => midi.withBackend((backend) {
  (backend as _Backend).bluetoothOverride = _BrokenScan();
  return null;
});

Future<void> _report(Midi midi, String cause) => midi.withBackend(
  (backend) => _fakeOf(backend).reportDiagnostic(
    MidiDiagnostic(
      kind: MidiDiagnosticKind.networkLoss,
      cause: cause,
      time: MidiTime.zero,
    ),
  ),
);

Future<void> _addPeripheral(Midi midi, String id) =>
    midi.withBackend((backend) {
      _fakeOf(backend).bluetooth!.addPeripheral(MidiBlePeripheralInfo(id: id));
      return null;
    });

Future<List<String>> _calls(Midi midi) =>
    midi.withBackend((backend) => _fakeOf(backend).calls);

Object? _exitIsolate(MidiBackend backend) => Isolate.exit();

Object? _holdThenExit(MidiBackend backend) {
  (backend as FakeMidiBackend).holdCalls();
  Timer(const Duration(milliseconds: 50), Isolate.exit);
  return null;
}

// .............................................................................
// Workers.

/// Attaches to [connector] twice and opens once from a new isolate and
/// returns the port names and whether all three are the same proxy.
Future<(List<String>, bool)> _attachFromWorker(MidiConnector connector) =>
    Isolate.run(() async {
      final both = await Future.wait([
        Midi.attach(connector),
        Midi.attach(connector),
      ]);
      final opened = await Midi.open();
      final names = [for (final port in opened.ports) port.name];
      final same =
          identical(both.first, both.last) && identical(both.first, opened);
      await opened.close();
      await both.first.close();
      await both.last.close();
      return (names, same);
    });

/// Attaches to [connector] from a new isolate that ends without closing.
Future<void> _attachAndExit(MidiConnector connector) => Isolate.run(() async {
  await Midi.attach(connector);
});

/// Opens a MIDI host of its own in a new isolate, attaches back to
/// [connector] and returns the name of the backend of each proxy.
Future<List<String>> _twoHosts(MidiConnector connector) =>
    Isolate.run(() async {
      final own = await Midi.open(options: const MidiOptions(backend: _bare));
      final other = await Midi.attach(connector);
      final names = [own.backendName, other.backendName];
      await other.close();
      await own.close();
      return names;
    });

/// Tries to attach to the in-isolate host of [connector] from a new
/// isolate and returns the error.
Future<Object> _attachLocalFromWorker(MidiConnector connector) =>
    Isolate.run(() async {
      try {
        await Midi.attach(connector);
        return 'attached';
      } on Object catch (error) {
        return error;
      }
    });

void main() {
  final opened = <Midi>[];

  Future<Midi> open({
    MidiBackendFactory backend = _backend,
    bool inIsolate = false,
  }) async {
    final midi = await Midi.open(
      options: MidiOptions(backend: backend, inIsolate: inIsolate),
    );
    opened.add(midi);
    return midi;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  tearDown(() async {
    for (final midi in opened) {
      while (!midi.isClosed) {
        try {
          await midi.close();
        } on Object {
          break;
        }
      }
    }
    opened.clear();
  });

  for (final inIsolate in [false, true]) {
    final mode = inIsolate ? 'in-isolate' : 'MIDI isolate';

    group('Midi ($mode)', () {
      group('open(options)', () {
        test('starts a host and returns the proxy of the isolate', () async {
          final midi = await open(inIsolate: inIsolate);
          expect(midi.isClosed, isFalse);
          expect(midi.backendName, 'fake');
          expect(midi.connector.isLocal, inIsolate);
          expect(midi.capabilities, FakeMidiBackend().capabilities);
          expect(midi.ports.map((port) => port.name), ['in', 'out']);
          expect(midi.inputs.map((input) => input.info.name), ['in']);
          expect(midi.outputs.map((output) => output.info.name), ['out']);
          expect(midi.devices.single.id, const MidiDeviceId('fake:dev'));
          expect(midi.virtualPorts, isNotNull);
          expect(midi.bluetooth, isNotNull);
          expect(midi.network, isNotNull);
        });

        test('returns the shared proxy and counts the references', () async {
          final both = await Future.wait([
            open(inIsolate: inIsolate),
            open(inIsolate: inIsolate),
          ]);
          final third = await open(inIsolate: inIsolate);
          expect(identical(both.first, both.last), isTrue);
          expect(identical(both.first, third), isTrue);
          await third.close();
          await both.first.close();
          expect(third.isClosed, isFalse);
          await both.last.close();
          expect(third.isClosed, isTrue);
          expect(await third.close().then((_) => 'again'), 'again');
        });

        test('waits for the previous host to shut down', () async {
          final first = await open(inIsolate: inIsolate);
          final closing = first.close();
          final second = await open(inIsolate: inIsolate);
          await closing;
          expect(identical(first, second), isFalse);
          expect(second.isClosed, isFalse);
        });

        test('describes a backend without sub-APIs', () async {
          final midi = await open(backend: _bare, inIsolate: inIsolate);
          expect(midi.virtualPorts, isNull);
          expect(midi.bluetooth, isNull);
          expect(midi.network, isNull);
        });

        test('rethrows what the backend threw', () async {
          await expectLater(
            open(backend: _refusing, inIsolate: inIsolate),
            throwsA(isA<MidiPermissionDenied>()),
          );
          final midi = await open(inIsolate: inIsolate);
          expect(midi.isClosed, isFalse);
        });
      });

      group('attach(connector)', () {
        test('returns the proxy of the isolate', () async {
          final midi = await open(inIsolate: inIsolate);
          final attached = await Midi.attach(midi.connector);
          expect(identical(attached, midi), isTrue);
          await attached.close();
          expect(midi.isClosed, isFalse);
        });
      });

      group('input(id), output(id)', () {
        test('return the handles of known ports', () async {
          final midi = await open(inIsolate: inIsolate);
          final input = midi.inputs.single;
          final output = midi.outputs.single;
          expect(midi.input(input.id), same(input));
          expect(midi.output(output.id), same(output));
          expect(midi.input(output.id), isNull);
          expect(midi.output(input.id), isNull);
          expect(midi.input(const MidiPortId('fake:none')), isNull);
          expect(midi.output(const MidiPortId('fake:none')), isNull);
        });
      });

      group('changes, replugCandidates(port)', () {
        test('follow the ports of the backend', () async {
          final midi = await open(inIsolate: inIsolate);
          final input = midi.inputs.single;
          final events = <MidiPortEvent>[];
          final subscription = midi.changes.listen(events.add);
          await _addInput(midi, 'twin');
          await _rename(midi, input.id, 'renamed');
          await settle();
          expect(input.info.name, 'renamed');
          final twin = midi.ports.firstWhere((port) => port.name == 'twin');
          expect(midi.replugCandidates(twin.copyWith(name: 'renamed')), [
            input.info,
          ]);
          await _remove(midi, input.id);
          await settle();
          expect(input.info.name, 'renamed');
          expect(midi.input(input.id), isNull);
          expect(events.map((event) => event.runtimeType), [
            MidiPortAdded,
            MidiPortChanged,
            MidiPortRemoved,
          ]);
          await subscription.cancel();
        });
      });

      group('capabilities', () {
        test('follow the backend', () async {
          final midi = await open(inIsolate: inIsolate);
          await _changeCapabilities(midi);
          await settle();
          expect(midi.capabilities, MidiCapabilities(ump: true));
        });
      });

      group('diagnostics, diagnosticsSnapshot()', () {
        test('report and count the losses', () async {
          final midi = await open(inIsolate: inIsolate);
          final diagnostics = <MidiDiagnostic>[];
          final subscription = midi.diagnostics.listen(diagnostics.add);
          await _report(midi, 'lost');
          await settle();
          expect(diagnostics.single.cause, 'lost');
          final snapshot = await midi.diagnosticsSnapshot();
          expect(snapshot.count(MidiDiagnosticKind.networkLoss), 1);
          await subscription.cancel();
        });
      });

      group('now()', () {
        test('reads the package clock', () async {
          final midi = await open(inIsolate: inIsolate);
          final before = const MidiSystemClock().now();
          final now = midi.now();
          expect(now.isBefore(before), isFalse);
          expect(now.difference(before), lessThan(const Duration(seconds: 1)));
        });
      });

      group('panic(panic)', () {
        test('silences the open outputs', () async {
          final midi = await open(inIsolate: inIsolate);
          final output = midi.outputs.single;
          await output.send(const MidiStart());
          await midi.panic(panic: const MidiPanic(channels: [0]));
          expect(await _calls(midi), contains('send fake:out'));
        });
      });

      group('withBackend(action)', () {
        test('returns the result of the action', () async {
          final midi = await open(inIsolate: inIsolate);
          expect(await midi.withBackend((backend) => backend.name), 'fake');
        });
      });

      group('close()', () {
        test('ends the streams and fails later calls', () async {
          final midi = await open(inIsolate: inIsolate);
          final input = midi.inputs.single;
          final done = Completer<void>();
          input.messages.listen((_) {}, onDone: done.complete);
          final scan = midi.bluetooth!.scan();
          await settle();
          await midi.close();
          await done.future;
          expect(await scan.toList(), isEmpty);
          await expectLater(midi.panic(), throwsA(isA<StateError>()));
          await expectLater(
            midi.diagnosticsSnapshot(),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                'The MIDI proxy is closed',
              ),
            ),
          );
          expect(await midi.changes.isEmpty, isTrue);
          expect(await midi.diagnostics.isEmpty, isTrue);
          expect(await midi.network!.sessionChanges.isEmpty, isTrue);
        });

        test('rethrows what the backend threw when it stopped', () async {
          final midi = await open(backend: _stopFailing, inIsolate: inIsolate);
          await expectLater(
            midi.close(),
            throwsA(isA<MidiNativeError>().having((e) => e.code, 'code', 7)),
          );
          expect(midi.isClosed, isTrue);
        });
      });

      group('network', () {
        test('follows the session', () async {
          final midi = await open(inIsolate: inIsolate);
          final changes = midi.network!.sessionChanges.first;
          await midi.network!.enable(name: 'Studio');
          expect((await changes).localName, 'Studio');
          expect(midi.network!.session.enabled, isTrue);
        });
      });

      group('bluetooth', () {
        test('streams scan results', () async {
          final midi = await open(inIsolate: inIsolate);
          await _addPeripheral(midi, 'p1');
          final found = await midi.bluetooth!.scan().first;
          expect(found.id, 'p1');
        });

        test('streams scan errors', () async {
          final midi = await open(inIsolate: inIsolate);
          await _breakScans(midi);
          await expectLater(
            midi.bluetooth!.scan().toList(),
            throwsA(isA<MidiPermissionDenied>()),
          );
          await expectLater(
            midi.bluetooth!.scan(timeout: const Duration(seconds: 1)).toList(),
            throwsA(isA<MidiUnsupported>()),
          );
        });

        test('cancels a scan at the host', () async {
          final midi = await open(inIsolate: inIsolate);
          final subscription = midi.bluetooth!.scan().listen((_) {});
          await settle();
          await subscription.cancel();
          await midi.bluetooth!.stopScan();
          final closing = midi.bluetooth!.scan().listen((_) {});
          await settle();
          final closed = midi.close();
          await closing.cancel();
          await closed;
        });
      });
    });
  }

  group('Midi (MIDI isolate)', () {
    test('lets workers attach through the connector', () async {
      final midi = await open();
      final (names, same) = await _attachFromWorker(midi.connector);
      expect(names, ['in', 'out']);
      expect(same, isTrue);
    });

    test('forgets a worker that ends without closing', () async {
      final midi = await open();
      await _attachAndExit(midi.connector);
      final exited = ReceivePort();
      (midi.connector.isolate! as Isolate).addOnExitListener(exited.sendPort);
      await midi.close();
      await exited.first.timeout(const Duration(seconds: 5));
    });

    test('keeps a proxy per host in an isolate', () async {
      final midi = await open();
      expect(await _twoHosts(midi.connector), ['fake', 'fake']);
    });

    test('closes the proxy when the MIDI isolate ends', () async {
      final midi = await open();
      final input = midi.inputs.single;
      final done = Completer<void>();
      input.messages.listen((_) {}, onDone: done.complete);
      await expectLater(
        midi.withBackend(_exitIsolate),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'The MIDI isolate ended',
          ),
        ),
      );
      await done.future;
      expect(midi.isClosed, isTrue);
      await midi.close();
      final again = await open();
      expect(identical(again, midi), isFalse);
    });

    test('completes a close when the MIDI isolate ends meanwhile', () async {
      final midi = await Midi.open(
        options: const MidiOptions(backend: _bareFake),
      );
      opened.add(midi);
      await midi.withBackend(_holdThenExit);
      await midi.close();
      expect(midi.isClosed, isTrue);
    });

    test('fails to attach to a host that ended', () async {
      final midi = await open();
      final connector = midi.connector;
      await midi.close();
      await expectLater(
        Midi.attach(connector, timeout: const Duration(milliseconds: 200)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'The MIDI host does not answer',
          ),
        ),
      );
    });

    test('fails to send what cannot reach the MIDI isolate', () async {
      final midi = await open();
      final port = ReceivePort();
      addTearDown(port.close);
      await expectLater(
        midi.withBackend((_) => port.sendPort),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Midi (in-isolate)', () {
    test('refuses workers', () async {
      final midi = await open(inIsolate: true);
      expect(
        await _attachLocalFromWorker(midi.connector),
        isA<MidiUnsupported>().having(
          (e) => e.feature,
          'feature',
          'Joining an in-isolate MIDI host',
        ),
      );
    });
  });
}

MidiBackend _bareFake() => FakeMidiBackend();
