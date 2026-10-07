// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi.dart';

// #############################################################################
/// Creates ports that other applications see, e.g. a source a sequencer
/// records from or a destination a synthesizer app plays into.
///
/// A source is an output of the app, a destination an input. The ports
/// appear in `Midi.changes` like any other, marked `isOwn`. On Android the
/// ports are declared statically in the manifest; creating one hands out a
/// declared port.
final class MidiVirtualPorts {
  MidiVirtualPorts._(this._midi);

  // ...........................................................................
  /// Creates a source named [name] that the app sends from and returns it.
  ///
  /// - [uniqueId] the id the port keeps across launches where the platform
  ///   supports it, e.g. a CoreMIDI unique id, so that other apps find
  ///   their connections again.
  /// - [protocol] the protocol of the port.
  /// - [groups] the UMP groups of a MIDI 2.0 port.
  /// - [manufacturer] and [model] describe the port to other apps.
  Future<MidiOutput> createSource(
    String name, {
    int? uniqueId,
    MidiProtocol protocol = MidiProtocol.midi1,
    List<int> groups = const [],
    String manufacturer = '',
    String model = '',
  }) async => _midi._outputOf(
    await _create(
      MidiVirtualPortSpec(
        name: name,
        direction: MidiDirection.output,
        uniqueId: uniqueId,
        protocol: protocol,
        groups: groups,
        manufacturer: manufacturer,
        model: model,
      ),
    ),
  );

  /// Creates a destination named [name] that other apps send to and
  /// returns it; the parameters are those of [createSource].
  Future<MidiInput> createDestination(
    String name, {
    int? uniqueId,
    MidiProtocol protocol = MidiProtocol.midi1,
    List<int> groups = const [],
    String manufacturer = '',
    String model = '',
  }) async => _midi._inputOf(
    await _create(
      MidiVirtualPortSpec(
        name: name,
        direction: MidiDirection.input,
        uniqueId: uniqueId,
        protocol: protocol,
        groups: groups,
        manufacturer: manufacturer,
        model: model,
      ),
    ),
  );

  /// Removes the own virtual port [port]; once the future completed, the
  /// port is gone from the known ports.
  Future<void> remove(MidiPortId port) => _midi._call<void>(
    (request) => MidiRemoveVirtualPortCommand(
      proxy: _midi._id,
      request: request,
      port: port,
    ),
  );

  // ...........................................................................
  /// Whether the platform creates virtual ports at runtime or only
  /// declares them statically.
  MidiVirtualPortSupport get support => _midi.capabilities.virtualPorts;

  // ...........................................................................
  final Midi _midi;

  /// Creates the port [spec] describes and adds it to the known ports.
  Future<MidiPortInfo> _create(MidiVirtualPortSpec spec) async {
    final port = await _midi._call<MidiPortInfo>(
      (request) => MidiCreateVirtualPortCommand(
        proxy: _midi._id,
        request: request,
        spec: spec,
      ),
    );
    _midi._applyPortEvents([MidiPortAdded(port: port)]);
    return port;
  }
}
