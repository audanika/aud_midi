// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi.dart';

// #############################################################################
/// The network MIDI session: the operating system's session on iOS,
/// AppleMIDI (RTP-MIDI) or Network MIDI 2.0 of `aud_midi_network`
/// elsewhere.
///
/// Every connection appears as an input and an output port. [session] is
/// kept current; [sessionChanges] reports every change.
final class MidiNetwork {
  MidiNetwork._(this._midi, this._session);

  // ...........................................................................
  /// Enables the session under [name] on [port] (null for the protocol's
  /// default) for the peers [policy] admits, announces it in the local
  /// network and returns its state.
  Future<MidiNetworkSessionInfo> enable({
    required String name,
    int? port,
    MidiNetworkConnectionPolicy policy = MidiNetworkConnectionPolicy.anyone,
  }) async => _session = await _midi._call<MidiNetworkSessionInfo>(
    (request) => MidiEnableNetworkCommand(
      proxy: _midi._id,
      request: request,
      name: name,
      port: port,
      policy: policy,
    ),
  );

  /// Disables the session; all connections end.
  Future<void> disable() => _midi._call<void>(
    (request) => MidiDisableNetworkCommand(proxy: _midi._id, request: request),
  );

  // ...........................................................................
  /// Connects to the session at [host] (a name or an address) and [port]
  /// and returns the connection once it is established.
  ///
  /// Throws a [MidiNetworkConnectionFailed] when the session refuses or
  /// does not answer.
  Future<MidiNetworkConnectionInfo> connect(String host, int port) =>
      connectTo(MidiNetworkHostInfo(name: host, address: host, port: port));

  /// Connects to [host], e.g. one that [browse] found, and returns the
  /// connection once it is established.
  ///
  /// Throws a [MidiNetworkConnectionFailed] when the session refuses or
  /// does not answer.
  Future<MidiNetworkConnectionInfo> connectTo(MidiNetworkHostInfo host) async {
    final connection = await _midi._call<MidiNetworkConnectionInfo>(
      (request) => MidiConnectHostCommand(
        proxy: _midi._id,
        request: request,
        host: host,
      ),
    );
    if (connection.state == MidiNetworkConnectionState.failed) {
      throw MidiNetworkConnectionFailed(connection);
    }
    return connection;
  }

  /// Ends the connection to [host].
  Future<void> disconnect(MidiNetworkHostInfo host) => _midi._call<void>(
    (request) => MidiDisconnectHostCommand(
      proxy: _midi._id,
      request: request,
      host: host,
    ),
  );

  /// Browses the local network for sessions and reports the current list
  /// of hosts after every change, until the subscription is cancelled.
  Stream<List<MidiNetworkHostInfo>> browse() =>
      _midi._hostStream<List<MidiNetworkHostInfo>>(
        (request, stream) => MidiBrowseCommand(
          proxy: _midi._id,
          request: request,
          stream: stream,
        ),
      );

  // ...........................................................................
  /// The current state of the session.
  MidiNetworkSessionInfo get session => _session;

  /// Reports every change of [session].
  Stream<MidiNetworkSessionInfo> get sessionChanges => _changes.stream;

  // ...........................................................................
  final Midi _midi;
  MidiNetworkSessionInfo _session;
  final _changes = StreamController<MidiNetworkSessionInfo>.broadcast();

  /// Takes over the new state [session] and reports it.
  void _update(MidiNetworkSessionInfo session) {
    _session = session;
    _changes.add(session);
  }

  /// Completes [sessionChanges].
  void _close() => unawaited(_changes.close());
}
