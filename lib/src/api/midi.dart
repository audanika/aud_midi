// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:collection';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../backend/midi_platform_backend.dart';
import '../isolate/midi_host.dart';
import '../isolate/midi_host_command.dart';
import '../isolate/midi_host_notice.dart';
import '../isolate/midi_host_snapshot.dart';
import '../isolate/midi_link.dart';
import '../isolate/midi_local_link.dart';
import '../isolate/midi_transport.dart';
import 'midi_connector.dart';
import 'midi_network_connection_failed.dart';
import 'midi_options.dart';

part 'midi_bluetooth.dart';
part 'midi_input.dart';
part 'midi_network.dart';
part 'midi_output.dart';
part 'midi_virtual_ports.dart';

// #############################################################################
/// The values, errors and end of a host stream, as the proxy hands them on;
/// streams of MIDI data take no errors.
typedef _MidiStreamReceiver = ({
  void Function(List<Object?> values) add,
  void Function(Object error, StackTrace stack)? addError,
  void Function() done,
});

// #############################################################################
/// The MIDI of the app as one isolate sees it: ports, devices, and the
/// sub-APIs for virtual ports, Bluetooth LE MIDI and network sessions.
///
/// [open] starts one long-lived MIDI isolate per process. It owns the
/// backend of the platform and every native resource, schedules timed
/// sends and stamps received messages, so that nothing the app's isolates
/// do — building frames, blocking, collecting garbage of their own — delays
/// MIDI. A `Midi` is a proxy that talks to it through ports. Every isolate
/// holds one proxy per MIDI isolate: [open] again in the same isolate
/// returns the same proxy and counts the reference, and other isolates
/// join with [attach] and the [connector] of a proxy. The last [close] of
/// the last proxy shuts the MIDI isolate down. In the browser, where Web
/// MIDI exists on the main thread only, the engine runs in the page
/// instead, behind the same API.
///
/// Ports are the primary entity: [inputs] and [outputs] are handles on
/// them, [devices] groups them. [changes] reports hotplug, [diagnostics]
/// every loss; streams of MIDI data never carry errors.
///
/// ```dart
/// final midi = await Midi.open();
/// final output = midi.outputs.first;
/// await output.send(MidiNoteOn(channel: 0, note: 60, velocity: 100));
/// await output.send(
///   MidiNoteOff(channel: 0, note: 60),
///   at: midi.now() + const Duration(milliseconds: 500),
/// );
/// await midi.close();
/// ```
final class Midi {
  Midi._(this.connector);

  // ...........................................................................
  /// Returns the handle on the input port [id], or null when no input has
  /// this id.
  MidiInput? input(MidiPortId id) {
    final port = _registry.port(id);
    return port != null && port.isInput ? _inputOf(port) : null;
  }

  /// Returns the handle on the output port [id], or null when no output
  /// has this id.
  MidiOutput? output(MidiPortId id) {
    final port = _registry.port(id);
    return port != null && port.isOutput ? _outputOf(port) : null;
  }

  /// Returns the other ports with the fingerprint of [port]: after a
  /// re-plug most likely the same port with a new id; several candidates
  /// are identical devices the app has to tell apart.
  List<MidiPortInfo> replugCandidates(MidiPortInfo port) =>
      _registry.replugCandidates(port);

  // ...........................................................................
  /// Returns the current time on the package clock, the clock of every
  /// timestamp and due time: the monotonic clock of the process, shared by
  /// all isolates and the MIDI isolate; `performance.now()` in the browser.
  MidiTime now() => const MidiSystemClock().now();

  /// Silences every open output of the MIDI isolate, of all isolates, as
  /// [panic] describes.
  Future<void> panic({MidiPanic panic = const MidiPanic()}) => _call<void>(
    (request) => MidiPanicCommand(proxy: _id, request: request, panic: panic),
  );

  /// Returns the diagnostic counters of the engine.
  Future<MidiDiagnosticsSnapshot> diagnosticsSnapshot() =>
      _call<MidiDiagnosticsSnapshot>(
        (request) => MidiDiagnosticsCommand(proxy: _id, request: request),
      );

  /// Runs [action] with the backend inside the MIDI isolate and returns
  /// its result, e.g. to reach a backend-specific feature.
  ///
  /// With a MIDI isolate, [action] and its result travel between isolates:
  /// [action] must be a top-level or static function, or a closure that
  /// captures sendable values only. A result that cannot travel fails with
  /// a [MidiRemoteError].
  Future<T> withBackend<T>(FutureOr<T> Function(MidiBackend backend) action) =>
      _call<T>(
        (request) => MidiWithBackendCommand(
          proxy: _id,
          request: request,
          action: action,
        ),
      );

  /// Gives back one reference of [open] or [attach]; the last one closes
  /// the proxy.
  ///
  /// Closing ends the streams of the proxy, closes its outputs and leaves
  /// the host; the last proxy of the host shuts the MIDI isolate down: it
  /// stops the native sources, waits for the sends in flight, discards
  /// what is scheduled and releases the native resources. Calls on a
  /// closed proxy fail with a [StateError].
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    if (_isClosed || --_references > 0) return Future.value();
    return _closing = _shutDown();
  }

  // ...........................................................................
  /// The connector other isolates join this proxy's MIDI isolate with.
  final MidiConnector connector;

  /// The name of the backend, e.g. `coremidi`, or of the composition of
  /// backends, e.g. `linux`.
  String get backendName => _backendName;

  /// What the backend supports, kept current.
  MidiCapabilities get capabilities => _capabilities;

  /// The known ports.
  List<MidiPortInfo> get ports => _registry.ports;

  /// The handles on the input ports, which deliver MIDI into the app.
  List<MidiInput> get inputs => [
    for (final port in _registry.inputs) _inputOf(port),
  ];

  /// The handles on the output ports, which carry MIDI out of the app.
  List<MidiOutput> get outputs => [
    for (final port in _registry.outputs) _outputOf(port),
  ];

  /// The devices of the known ports.
  List<MidiDeviceInfo> get devices => _registry.devices;

  /// The ports that appear, disappear or change.
  Stream<MidiPortEvent> get changes => _registry.events;

  /// The losses and faults of the MIDI isolate and of this proxy.
  Stream<MidiDiagnostic> get diagnostics => _diagnostics.stream;

  /// The virtual ports, or null when the platform cannot create any.
  MidiVirtualPorts? get virtualPorts => _virtualPorts;

  /// Bluetooth LE MIDI, or null when the backend cannot scan.
  MidiBluetooth? get bluetooth => _bluetooth;

  /// The network session, or null when the backend has none.
  MidiNetwork? get network => _network;

  /// Whether the proxy is closed.
  bool get isClosed => _isClosed;

  // ...........................................................................
  /// Opens MIDI and returns the proxy of the calling isolate.
  ///
  /// The first call of an isolate starts a MIDI host with [options]: in a
  /// MIDI isolate of its own, or in the calling isolate in the browser and
  /// with [MidiOptions.inIsolate]. Later calls of the same isolate return
  /// the same proxy, also one created by [attach], and ignore [options];
  /// each call needs one [close].
  ///
  /// Throws what starting the backend throws, e.g. a
  /// `MidiPermissionDenied` or a `MidiUnsupported`.
  static Future<Midi> open({MidiOptions options = const MidiOptions()}) async {
    final shared = _sharedHost == null ? null : _proxies[_sharedHost];
    if (shared != null) return shared.._references += 1;
    final launched = await (_launching ??= _launch(
      options,
    ).whenComplete(() => _launching = null));
    return launched.._references += 1;
  }

  /// Joins the MIDI host of [connector] from the calling isolate and
  /// returns the proxy of this isolate for it.
  ///
  /// Proxies are shared per isolate and host like those of [open]; each
  /// call needs one [close]. Throws a `MidiUnsupported` for the connector
  /// of a host that runs in another isolate without a MIDI isolate of its
  /// own, and a [StateError] when the host shuts down or does not answer
  /// within [timeout], e.g. because its MIDI isolate ended.
  static Future<Midi> attach(
    MidiConnector connector, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final known = _proxies[connector.host];
    if (known != null) return known.._references += 1;
    final midi = await (_attaching[connector.host] ??=
        _connect(connector, timeout: timeout).whenComplete(() {
          _attaching.remove(connector.host);
        }));
    _sharedHost ??= connector.host;
    return midi.._references += 1;
  }

  // ...........................................................................
  late final MidiLink _link;
  final _registry = MidiPortRegistry();
  final _diagnostics = StreamController<MidiDiagnostic>.broadcast();
  final _requests = <int, Completer<Object?>>{};
  final _streams = <int, _MidiStreamReceiver>{};
  final _inputs = <MidiPortId, MidiInput>{};
  final _outputs = <MidiPortId, MidiOutput>{};
  final _feeds = <MidiPortId, Set<_MidiInputFeed<Object?>>>{};
  int _id = 0;
  int _references = 0;
  int _nextRequest = 1;
  int _nextStream = 1;
  String _backendName = '';
  MidiCapabilities _capabilities = const MidiCapabilities.none();
  MidiVirtualPorts? _virtualPorts;
  MidiBluetooth? _bluetooth;
  MidiNetwork? _network;
  Future<void>? _closing;
  bool _isClosed = false;

  /// The open proxies of this isolate by the id of their host.
  static final _proxies = <int, Midi>{};

  /// The proxies of this isolate that join a host right now.
  static final _attaching = <int, Future<Midi>>{};

  /// The hosts that run in this isolate by their id.
  static final _localHosts = <int, MidiHost>{};

  /// The host whose proxy [open] returns.
  static int? _sharedHost;

  /// The start of the host of [open] while it runs.
  static Future<Midi>? _launching;

  /// The shutdown of the last host of [open] while it runs.
  static Future<void>? _sharedClosing;

  /// Starts a host for [options] and joins it.
  static Future<Midi> _launch(MidiOptions options) async {
    await _sharedClosing;
    final connector = options.inIsolate || !midiIsolatesSupported
        ? await _startLocalHost(options)
        : await midiSpawnHost(options);
    final midi = await _connect(connector);
    _sharedHost = connector.host;
    return midi;
  }

  /// Starts a host for [options] in this isolate.
  static Future<MidiConnector> _startLocalHost(MidiOptions options) async {
    final factory = options.backend;
    final host = MidiHost(
      backend: factory == null ? midiPlatformBackend(options) : factory(),
      options: options.engineFor(inMidiIsolate: false),
    );
    await host.start();
    _localHosts[host.id] = host;
    unawaited(
      host.done.whenComplete(() {
        _localHosts.remove(host.id);
      }),
    );
    return MidiConnector(host: host.id);
  }

  /// Creates a proxy that joins the host of [connector]; the host has to
  /// answer within [timeout] when one is given.
  static Future<Midi> _connect(
    MidiConnector connector, {
    Duration? timeout,
  }) async {
    final midi = Midi._(connector);
    final host = connector.isLocal ? _localHosts[connector.host] : null;
    if (connector.isLocal && host == null) {
      throw const MidiUnsupported('Joining an in-isolate MIDI host');
    }
    midi._link = host == null
        ? midiRemoteLink(connector: connector, onNotice: midi._onNotice)
        : MidiLocalLink(host: host, onNotice: midi._onNotice);
    try {
      final hello = midi._request<MidiHostSnapshot>(
        (request) => MidiHelloCommand(request: request, sink: midi._link.sink),
      );
      await (timeout == null
          ? hello
          : hello.timeout(
              timeout,
              onTimeout: () =>
                  throw StateError('The MIDI host does not answer'),
            ));
    } on Object {
      midi._link.close();
      rethrow;
    }
    _proxies[connector.host] = midi;
    return midi;
  }

  // ...........................................................................
  /// Sends the command [command] builds for a new request and returns the
  /// answer; fails with a [StateError] once the proxy closes.
  Future<T> _call<T>(MidiHostCommand Function(int request) command) =>
      _closing != null || _isClosed
      ? Future.error(StateError('The MIDI proxy is closed'))
      : Future.sync(() => _request<T>(command));

  /// Sends the command [command] builds for a new request and returns the
  /// answer.
  Future<T> _request<T>(MidiHostCommand Function(int request) command) {
    final request = _nextRequest++;
    final completer = Completer<Object?>();
    _requests[request] = completer;
    try {
      _link.send(command(request));
    } on Object {
      _requests.remove(request);
      rethrow;
    }
    return completer.future.then((value) => value as T);
  }

  /// Starts the host stream that [command] opens and returns its values;
  /// cancelling the subscription ends the host stream.
  ///
  /// A command that fails turns into an error and the end of the stream.
  Stream<T> _hostStream<T>(
    MidiHostRequest Function(int request, int stream) command,
  ) {
    late final StreamController<T> controller;
    var stream = 0;
    controller = StreamController<T>(
      onListen: () {
        if (_closing != null || _isClosed) {
          unawaited(controller.close());
          return;
        }
        final id = stream = _nextStream++;
        _streams[id] = (
          add: (values) => values.cast<T>().forEach(controller.add),
          addError: controller.addError,
          done: controller.close,
        );
        unawaited(
          _request<void>((request) => command(request, id)).then(
            (_) {},
            onError: (Object error, StackTrace stack) {
              if (_streams.remove(id) == null) return;
              controller.addError(error, stack);
              unawaited(controller.close());
            },
          ),
        );
      },
      onCancel: () => _cancelStream(stream),
    );
    return controller.stream;
  }

  /// Ends the host stream [id] at the host, unless it ended already.
  Future<void> _cancelStream(int id) async {
    if (_streams.remove(id) == null || _closing != null || _isClosed) return;
    await _request<void>(
      (request) =>
          MidiCancelStreamCommand(proxy: _id, request: request, stream: id),
    ).then((_) {}, onError: (Object _) {});
  }

  /// Returns the handle on the input [port].
  MidiInput _inputOf(MidiPortInfo port) =>
      _inputs[port.id] ??= MidiInput._(this, port);

  /// Returns the handle on the output [port].
  MidiOutput _outputOf(MidiPortInfo port) =>
      _outputs[port.id] ??= MidiOutput._(this, port);

  /// Returns the input feeds of [port] that have listeners.
  Set<_MidiInputFeed<Object?>> _feedsOf(MidiPortId port) => _feeds[port] ??= {};

  /// Publishes [diagnostic] of this proxy.
  void _report(MidiDiagnostic diagnostic) {
    if (!_diagnostics.isClosed) _diagnostics.add(diagnostic);
  }

  // ...........................................................................
  /// Takes over what the host tells in [notice].
  void _onNotice(MidiHostNotice notice) {
    switch (notice) {
      case MidiNoticeBatch(:final notices):
        notices.forEach(_onNotice);
      case MidiReplyNotice(:final request, :final value):
        if (value is MidiHostSnapshot) _start(value);
        _requests.remove(request)?.complete(value);
      case MidiFailureNotice(:final request, :final error, :final stack):
        _requests
            .remove(request)
            ?.completeError(error, StackTrace.fromString(stack));
      case MidiPortsNotice(:final events):
        _applyPortEvents(events);
      case MidiDiagnosticsNotice(:final diagnostics):
        diagnostics.forEach(_report);
      case MidiCapabilitiesNotice(:final capabilities):
        _capabilities = capabilities;
      case MidiSessionNotice(:final session):
        _network?._update(session);
      case MidiStreamNotice(:final stream, :final values):
        _streams[stream]?.add(values);
      case MidiStreamErrorNotice(:final stream, :final error, :final stack):
        _streams[stream]?.addError?.call(error, StackTrace.fromString(stack));
      case MidiStreamDoneNotice(:final stream):
        _streams.remove(stream)?.done();
      case MidiHostExitNotice():
        _lost();
    }
  }

  /// Takes over the state of the host from [snapshot].
  void _start(MidiHostSnapshot snapshot) {
    _id = snapshot.proxy;
    _backendName = snapshot.backend;
    _capabilities = snapshot.capabilities;
    _registry.reset(snapshot.ports);
    if (snapshot.hasVirtualPorts) _virtualPorts = MidiVirtualPorts._(this);
    if (snapshot.hasBluetooth) _bluetooth = MidiBluetooth._(this);
    final session = snapshot.session;
    if (session != null) _network = MidiNetwork._(this, session);
    _link.watch(proxy: _id);
  }

  /// Applies the port [events] and updates the handles of the ports.
  void _applyPortEvents(List<MidiPortEvent> events) {
    for (final event in _registry.apply(events)) {
      final port = event.port;
      switch (event) {
        case MidiPortRemoved():
          _inputs.remove(port.id)?._info = port;
          _outputs.remove(port.id)?._info = port;
        case MidiPortAdded() || MidiPortChanged():
          _inputs[port.id]?._info = port;
          _outputs[port.id]?._info = port;
      }
    }
  }

  // ...........................................................................
  /// Leaves the host and closes the proxy.
  Future<void> _shutDown() async {
    final closed = Completer<void>();
    if (_sharedHost == connector.host) {
      _sharedHost = null;
      _sharedClosing = closed.future;
    }
    _forget();
    _endStreams();
    try {
      await _request<bool>(
        (request) => MidiGoodbyeCommand(proxy: _id, request: request),
      );
    } on Object {
      if (!_isClosed) rethrow;
    } finally {
      _finish(StateError('The MIDI proxy is closed'));
      closed.complete();
      if (identical(_sharedClosing, closed.future)) _sharedClosing = null;
    }
  }

  /// Closes the proxy after its MIDI isolate ended unexpectedly; a close
  /// that waits for the host completes.
  void _lost() {
    if (_isClosed) return;
    if (_closing == null) {
      if (_sharedHost == connector.host) _sharedHost = null;
      _forget();
      _endStreams();
    }
    _finish(StateError('The MIDI isolate ended'));
  }

  /// Removes the proxy from the proxies of this isolate.
  void _forget() {
    if (identical(_proxies[connector.host], this)) {
      _proxies.remove(connector.host);
    }
  }

  /// Ends every stream the proxy receives from its host.
  void _endStreams() {
    final streams = [..._streams.values];
    _streams.clear();
    for (final stream in streams) {
      stream.done();
    }
  }

  /// Fails the open requests with [error], closes the link and completes
  /// the streams of the proxy.
  void _finish(Object error) {
    _isClosed = true;
    _link.close();
    final requests = [..._requests.values];
    _requests.clear();
    for (final request in requests) {
      request.completeError(error);
    }
    _network?._close();
    unawaited(_registry.close());
    unawaited(_diagnostics.close());
  }
}
