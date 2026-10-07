// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi.dart';

// #############################################################################
/// Finds and connects Bluetooth LE MIDI peripherals.
///
/// A connected peripheral appears as an input and an output port. On
/// Apple platforms the app needs the usage description
/// `NSBluetoothAlwaysUsageDescription`; without it the operating system
/// ends the process at the first scan.
final class MidiBluetooth {
  MidiBluetooth._(this._midi);

  // ...........................................................................
  /// Scans for peripherals that advertise the BLE-MIDI service and reports
  /// each finding; the stream ends after [timeout], on [stopScan] or when
  /// the subscription is cancelled. A scan that cannot start, e.g. without
  /// permission, ends with that error.
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) =>
      _midi._hostStream<MidiBlePeripheralInfo>(
        (request, stream) => MidiScanCommand(
          proxy: _midi._id,
          request: request,
          stream: stream,
          timeout: timeout,
        ),
      );

  /// Stops the running scans.
  Future<void> stopScan() => _midi._call<void>(
    (request) => MidiStopScanCommand(proxy: _midi._id, request: request),
  );

  // ...........................................................................
  /// Connects the peripheral [peripheralId] and returns its ports.
  ///
  /// Throws a `MidiException` when the connection does not succeed within
  /// [timeout].
  Future<List<MidiPortInfo>> connect(
    String peripheralId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final ports = await _midi._call<List<MidiPortInfo>>(
      (request) => MidiConnectPeripheralCommand(
        proxy: _midi._id,
        request: request,
        peripheral: peripheralId,
        timeout: timeout,
      ),
    );
    _midi._applyPortEvents([
      for (final port in ports) MidiPortAdded(port: port),
    ]);
    return ports;
  }

  /// Disconnects the peripheral [peripheralId]; its ports disappear.
  Future<void> disconnect(String peripheralId) => _midi._call<void>(
    (request) => MidiDisconnectPeripheralCommand(
      proxy: _midi._id,
      request: request,
      peripheral: peripheralId,
    ),
  );

  // ...........................................................................
  final Midi _midi;
}
