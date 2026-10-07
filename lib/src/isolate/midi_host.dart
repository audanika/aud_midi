// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../api/midi_remote_error.dart';
import 'midi_host_command.dart';
import 'midi_host_notice.dart';
import 'midi_host_snapshot.dart';

// #############################################################################
/// Hosts the engine with one backend and serves the proxies of every
/// isolate that uses it.
///
/// The host is what runs in the MIDI isolate; in the browser, and with
/// `MidiOptions.inIsolate`, it runs in the isolate of its proxies. It does
/// not know how commands reach it: a launcher feeds them to [handle], and
/// every proxy names the sink of its notices in its [MidiHelloCommand].
///
/// - Every command gets an answer, in the order the work completes.
/// - Port events, diagnostics, network session changes and capability
///   changes go to every proxy.
/// - Input events, raw packets, scan results and browse results go to the
///   proxy that asked for them, as host streams.
/// - The notices of one turn of the event loop leave as one batch.
/// - When the last proxy left, the host closes the engine in its shutdown
///   order and completes [done].
final class MidiHost {
  /// Creates a host for [backend].
  ///
  /// - [options] the settings of the engine.
  /// - [clock] the package clock, the system clock by default.
  /// - [timerFactory] creates the timers of the software scheduler.
  /// - [id] the id of the host, random by default.
  MidiHost({
    required MidiBackend backend,
    MidiEngineOptions options = const MidiEngineOptions(),
    MidiClock clock = const MidiSystemClock(),
    MidiTimerFactory timerFactory = Timer.new,
    int? id,
  }) : id = id ?? Random.secure().nextInt(1 << 32),
       engine = MidiEngine(
         backend: backend,
         clock: clock,
         options: options,
         timerFactory: timerFactory,
       );

  // ...........................................................................
  /// Opens the engine and starts to forward what it reports.
  ///
  /// Throws what opening the engine throws, e.g. a `MidiPermissionDenied`;
  /// the host is closed then.
  Future<void> start() async {
    _diagnostics = engine.diagnostics.listen(_onDiagnostic);
    try {
      await engine.open();
    } on Object {
      await _diagnostics?.cancel();
      await engine.close();
      _done.complete();
      rethrow;
    }
    _capabilities = engine.capabilities;
    _portEvents = engine.portEvents.listen(_onPortEvent);
    _sessions = engine.network?.sessionChanges.listen(_onSession);
  }

  /// Handles [command] of a proxy; commands of proxies that are unknown or
  /// leaving are ignored.
  void handle(MidiHostCommand command) {
    switch (command) {
      case MidiHelloCommand():
        _hello(command);
      case MidiGoodbyeCommand(:final proxy, :final request):
        final known = _proxies[proxy];
        if (known != null && !known.isLeaving) {
          unawaited(_goodbye(known, request));
        }
      case final MidiHostRequest request:
        final known = _proxies[request.proxy];
        if (known == null || known.isLeaving) return;
        known.serve(request.request, () => _run(known, request));
    }
  }

  /// Reports an error nobody caught in the MIDI isolate as a
  /// [MidiDiagnosticKind.nativeError] diagnostic to every proxy.
  void reportError(Object error, StackTrace stack) => _onDiagnostic(
    MidiDiagnostic(
      kind: MidiDiagnosticKind.nativeError,
      cause: 'Uncaught error in the MIDI isolate: $error',
      time: engine.clock.now(),
    ),
  );

  // ...........................................................................
  /// The id of the host, unique within the process.
  final int id;

  /// The engine with the backend.
  final MidiEngine engine;

  /// The number of registered proxies.
  int get proxyCount => _proxies.length;

  /// Completes when the host shut down after its last proxy left, or when
  /// it failed to start.
  Future<void> get done => _done.future;

  /// Whether the host shut down.
  bool get isClosed => _done.isCompleted;

  // ...........................................................................
  /// The number of diagnostics kept for the first proxy.
  static const int earlyDiagnostics = 64;

  // ...........................................................................
  final _proxies = <int, _HostProxy>{};
  final _done = Completer<void>();
  final _early = <MidiDiagnostic>[];
  StreamSubscription<MidiDiagnostic>? _diagnostics;
  StreamSubscription<MidiPortEvent>? _portEvents;
  StreamSubscription<MidiNetworkSessionInfo>? _sessions;
  MidiCapabilities _capabilities = const MidiCapabilities.none();
  int _lastProxy = 0;
  bool _isClosing = false;

  /// The Bluetooth LE MIDI support of the backend, or throws.
  MidiBluetoothBackend get _bluetooth =>
      engine.bluetooth ?? (throw const MidiUnsupported('Bluetooth LE MIDI'));

  /// The network session of the backend, or throws.
  MidiNetworkBackend get _network =>
      engine.network ?? (throw const MidiUnsupported('Network sessions'));

  /// Registers the proxy of [command] and answers with a snapshot.
  void _hello(MidiHelloCommand command) {
    if (_isClosing || isClosed) {
      command.sink(
        MidiFailureNotice(
          request: command.request,
          error: StateError('The MIDI host shuts down'),
          stack: '${StackTrace.current}',
        ),
      );
      return;
    }
    final proxy = _HostProxy(id: ++_lastProxy, sink: command.sink, host: this);
    _proxies[proxy.id] = proxy;
    proxy.post(
      MidiReplyNotice(
        request: command.request,
        value: MidiHostSnapshot(
          proxy: proxy.id,
          backend: engine.backend.name,
          capabilities: _capabilities,
          ports: engine.ports,
          hasVirtualPorts: engine.virtualPorts != null,
          hasBluetooth: engine.bluetooth != null,
          session: engine.network?.session,
        ),
      ),
    );
    _early.forEach(proxy.postDiagnostic);
    _early.clear();
  }

  /// Releases [proxy], shuts down after the last one and answers
  /// [request] with whether the host shut down.
  Future<void> _goodbye(_HostProxy proxy, int request) async {
    await proxy.release();
    _proxies.remove(proxy.id);
    final isLast = _proxies.isEmpty;
    try {
      if (isLast) await _shutDown();
      proxy.post(MidiReplyNotice(request: request, value: isLast));
    } on Object catch (error, stack) {
      proxy.post(
        MidiFailureNotice(request: request, error: error, stack: '$stack'),
      );
    }
    proxy.flush();
    if (isLast) _done.complete();
  }

  /// Closes the engine in its shutdown order and stops forwarding.
  Future<void> _shutDown() async {
    _isClosing = true;
    try {
      await engine.close();
    } finally {
      await _portEvents?.cancel();
      await _sessions?.cancel();
      await _diagnostics?.cancel();
    }
  }

  /// Runs [request] of [proxy] and returns its result.
  Future<Object?> _run(_HostProxy proxy, MidiHostRequest request) async {
    switch (request) {
      case final MidiOpenInputCommand command:
        await _openInput(proxy, command);
      case MidiScanCommand(:final stream, :final timeout):
        proxy.startStream(stream, _bluetooth.scan(timeout: timeout));
      case MidiBrowseCommand(:final stream):
        proxy.startStream(stream, _network.browse());
      case MidiCancelStreamCommand(:final stream):
        await proxy.cancelStream(stream);
      case MidiSendCommand(
        :final port,
        :final messages,
        :final at,
        :final group,
      ):
        await proxy.withOutput(
          port,
          (output) => output.sendAll(messages, at: at, group: group),
        );
      case MidiSendPacketCommand(:final port, :final packet):
        await proxy.withOutput(port, (output) => output.sendPacket(packet));
      case MidiCancelPendingCommand(:final port):
        return proxy.withOutput(port, (output) => output.cancelPending());
      case MidiOutputPanicCommand(:final port, :final panic):
        await proxy.withOutput(port, (output) => output.panic(panic: panic));
      case MidiCloseOutputCommand(:final port):
        await proxy.closeOutput(port);
      case MidiPanicCommand(:final panic):
        await engine.panic(panic: panic);
      case MidiDiagnosticsCommand():
        return engine.diagnosticsSnapshot();
      case MidiWithBackendCommand(:final action):
        return action(engine.backend);
      case MidiCreateVirtualPortCommand(:final spec):
        return engine.createVirtualPort(spec);
      case MidiRemoveVirtualPortCommand(:final port):
        await engine.removeVirtualPort(port);
      case MidiStopScanCommand():
        await _bluetooth.stopScan();
      case MidiConnectPeripheralCommand(:final peripheral, :final timeout):
        return _bluetooth.connect(peripheral, timeout: timeout);
      case MidiDisconnectPeripheralCommand(:final peripheral):
        await _bluetooth.disconnect(peripheral);
      case MidiEnableNetworkCommand(:final name, :final port, :final policy):
        return _network.enable(name: name, port: port, policy: policy);
      case MidiDisableNetworkCommand():
        await _network.disable();
      case MidiConnectHostCommand(:final host):
        return _network.connect(host);
      case MidiDisconnectHostCommand(:final host):
        await _network.disconnect(host);
    }
    return null;
  }

  /// Opens the input session of [command] and forwards its events or
  /// packets as a host stream; a stream cancelled meanwhile closes the
  /// session again.
  Future<void> _openInput(
    _HostProxy proxy,
    MidiOpenInputCommand command,
  ) async {
    final stream = proxy.reserveStream(command.stream);
    final MidiInputSession session;
    try {
      session = await engine.openInput(command.port, options: command.options);
    } on Object {
      proxy.forgetStream(command.stream, stream);
      rethrow;
    }
    if (stream.isCancelled) {
      await session.close();
      return;
    }
    proxy.startStream(
      command.stream,
      command.raw ? session.packets : session.events,
      close: session.close,
    );
  }

  // ...........................................................................
  /// Forwards [event] to every proxy.
  void _onPortEvent(MidiPortEvent event) {
    for (final proxy in _proxies.values) {
      proxy.postPortEvent(event);
    }
    _checkCapabilities();
  }

  /// Forwards [diagnostic] to every proxy; before the first proxy arrived,
  /// the newest ones are kept for it.
  void _onDiagnostic(MidiDiagnostic diagnostic) {
    if (_lastProxy == 0) {
      if (_early.length == earlyDiagnostics) _early.removeAt(0);
      _early.add(diagnostic);
      return;
    }
    for (final proxy in _proxies.values) {
      proxy.postDiagnostic(diagnostic);
    }
  }

  /// Forwards the new state [session] of the network session.
  void _onSession(MidiNetworkSessionInfo session) {
    _broadcast(MidiSessionNotice(session: session));
    _checkCapabilities();
  }

  /// Tells every proxy when the capabilities of the backend changed.
  void _checkCapabilities() {
    final capabilities = engine.capabilities;
    if (capabilities == _capabilities) return;
    _capabilities = capabilities;
    _broadcast(MidiCapabilitiesNotice(capabilities: capabilities));
  }

  /// Posts [notice] to every proxy.
  void _broadcast(MidiHostNotice notice) {
    for (final proxy in _proxies.values) {
      proxy.post(notice);
    }
  }
}

// #############################################################################
/// A registered proxy of a [MidiHost] with its streams, outputs and the
/// notices that wait to leave.
final class _HostProxy {
  _HostProxy({required this.id, required this.sink, required this.host});

  // ...........................................................................
  /// Runs [work] for [request] and posts its result or failure.
  void serve(int request, Future<Object?> Function() work) {
    late final Future<void> served;
    served = Future.sync(work)
        .then<void>(
          (value) => post(MidiReplyNotice(request: request, value: value)),
          onError: (Object error, StackTrace stack) => post(
            MidiFailureNotice(request: request, error: error, stack: '$stack'),
          ),
        )
        .whenComplete(() => _pending.remove(served));
    _pending.add(served);
  }

  /// Waits for the pending commands, then ends the streams and closes the
  /// outputs of the proxy.
  Future<void> release() async {
    isLeaving = true;
    await Future.wait([..._pending]);
    for (final stream in [..._streams.keys]) {
      await cancelStream(stream);
    }
    for (final port in [..._outputs.keys]) {
      await closeOutput(port);
    }
  }

  // ...........................................................................
  /// Returns the stream [id], created as a placeholder until its source is
  /// ready, so that a cancel arriving meanwhile can find it.
  _HostStream reserveStream(int id) => _streams[id] ??= _HostStream();

  /// Forgets the placeholder [stream] of [id] whose source failed.
  void forgetStream(int id, _HostStream stream) {
    if (identical(_streams[id], stream)) _streams.remove(id);
  }

  /// Forwards [values] as the stream [id]; [close] releases the source
  /// when the proxy cancels the stream.
  void startStream(
    int id,
    Stream<Object?> values, {
    Future<void> Function()? close,
  }) {
    final stream = reserveStream(id)..close = close;
    stream.subscription = values.listen(
      (value) => _postValue(id, value),
      onError: (Object error, StackTrace stack) => post(
        MidiStreamErrorNotice(stream: id, error: error, stack: '$stack'),
      ),
      onDone: () {
        forgetStream(id, stream);
        post(MidiStreamDoneNotice(stream: id));
      },
    );
  }

  /// Ends the stream [id] at the request of the proxy.
  Future<void> cancelStream(int id) async => _streams.remove(id)?.cancel();

  // ...........................................................................
  /// Runs [action] with the output session of [port], which is opened
  /// first when needed; actions wait for the opening in their order.
  Future<T> withOutput<T>(
    MidiPortId port,
    Future<T> Function(MidiOutputSession session) action,
  ) {
    final output = _outputs.putIfAbsent(port, _HostOutput.new);
    final session = output.session;
    if (output.opening == null && session != null && !session.isClosed) {
      return action(session);
    }
    final opening = output.opening ??= _open(output, port);
    return opening.then(action);
  }

  /// Closes the output session of [port]; an output that failed to open is
  /// just forgotten.
  Future<void> closeOutput(MidiPortId port) async {
    final output = _outputs.remove(port);
    if (output == null) return;
    MidiOutputSession? session;
    try {
      session = await (output.opening ?? Future.value(output.session));
    } on Object {
      return;
    }
    await session?.close();
  }

  // ...........................................................................
  /// Queues [notice] to leave at the end of the turn.
  void post(MidiHostNotice notice) {
    _outbox.add(notice);
    _schedule();
  }

  /// Queues [event], merged into a port notice that waits already.
  void postPortEvent(MidiPortEvent event) {
    if (_outbox.lastOrNull case MidiPortsNotice(:final events)) {
      events.add(event);
      return;
    }
    post(MidiPortsNotice(events: [event]));
  }

  /// Queues [diagnostic], merged into a diagnostics notice that waits
  /// already.
  void postDiagnostic(MidiDiagnostic diagnostic) {
    if (_outbox.lastOrNull case MidiDiagnosticsNotice(:final diagnostics)) {
      diagnostics.add(diagnostic);
      return;
    }
    post(MidiDiagnosticsNotice(diagnostics: [diagnostic]));
  }

  /// Sends the waiting notices as one message.
  ///
  /// When the message cannot leave the isolate, the notices go one by one,
  /// and a notice that cannot leave is replaced by a stand-in: a
  /// [MidiRemoteError] for an answer, a diagnostic for anything else.
  void flush() {
    _isScheduled = false;
    if (_outbox.isEmpty) return;
    final notices = [..._outbox];
    _outbox.clear();
    try {
      sink(
        notices.length == 1
            ? notices.single
            : MidiNoticeBatch(notices: notices),
      );
    } on Object {
      notices.forEach(_sendAlone);
    }
  }

  // ...........................................................................
  /// The id the host gave the proxy.
  final int id;

  /// Receives the notices of the proxy.
  final MidiNoticeSink sink;

  /// The host of the proxy.
  final MidiHost host;

  /// Whether the proxy is leaving; its commands are ignored then.
  bool isLeaving = false;

  // ...........................................................................
  final _streams = <int, _HostStream>{};
  final _outputs = <MidiPortId, _HostOutput>{};
  final _pending = <Future<void>>{};
  final _outbox = <MidiHostNotice>[];
  bool _isScheduled = false;

  /// Queues [value] of the stream [id], merged into a stream notice of the
  /// same stream that waits already.
  void _postValue(int id, Object? value) {
    if (_outbox.lastOrNull case MidiStreamNotice(
      :final stream,
      :final values,
    ) when stream == id) {
      values.add(value);
      return;
    }
    post(MidiStreamNotice(stream: id, values: [value]));
  }

  /// Schedules [flush] once per turn of the event loop, after the
  /// microtasks of the turn, so that everything the turn posts leaves as
  /// one message.
  void _schedule() {
    if (_isScheduled) return;
    _isScheduled = true;
    Timer.run(flush);
  }

  /// Opens the output session of [port] for [output].
  Future<MidiOutputSession> _open(_HostOutput output, MidiPortId port) async {
    try {
      return output.session = await host.engine.openOutput(port);
    } finally {
      output.opening = null;
    }
  }

  /// Sends [notice] on its own, or its stand-in when it cannot leave.
  void _sendAlone(MidiHostNotice notice) {
    try {
      sink(notice);
    } on Object catch (error) {
      sink(_standIn(notice, error));
    }
  }

  /// Returns what is sent instead of [notice], which failed with [error].
  MidiHostNotice _standIn(MidiHostNotice notice, Object error) =>
      switch (notice) {
        MidiReplyNotice(:final request, :final value) => MidiFailureNotice(
          request: request,
          error: MidiRemoteError(
            type: '${value.runtimeType}',
            message: 'The result cannot leave the MIDI isolate: $error',
          ),
          stack: '',
        ),
        MidiFailureNotice(
          :final request,
          error: final original,
          :final stack,
        ) =>
          MidiFailureNotice(
            request: request,
            error: MidiRemoteError(
              type: '${original.runtimeType}',
              message: '$original',
            ),
            stack: stack,
          ),
        _ => MidiDiagnosticsNotice(
          diagnostics: [
            MidiDiagnostic(
              kind: MidiDiagnosticKind.nativeError,
              cause:
                  'A ${notice.runtimeType} could not leave the MIDI isolate: '
                  '$error',
              time: host.engine.clock.now(),
            ),
          ],
        ),
      };
}

// #############################################################################
/// A stream a proxy receives from its host.
final class _HostStream {
  // ...........................................................................
  /// Ends the stream and releases its source.
  Future<void> cancel() async {
    isCancelled = true;
    await subscription?.cancel();
    await close?.call();
  }

  // ...........................................................................
  /// The subscription to the source, null while the source opens.
  StreamSubscription<Object?>? subscription;

  /// Releases the source, e.g. closes an input session.
  Future<void> Function()? close;

  /// Whether the proxy cancelled the stream.
  bool isCancelled = false;
}

// #############################################################################
/// The output session a proxy holds on one port.
final class _HostOutput {
  // ...........................................................................
  /// The session once it is open.
  MidiOutputSession? session;

  /// The opening of the session while it runs.
  Future<MidiOutputSession>? opening;
}
