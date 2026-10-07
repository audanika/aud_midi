// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi.dart';

// #############################################################################
/// The handle on an input port, which delivers MIDI into the app.
///
/// [messages] and [packets] open the port in the MIDI isolate when the
/// first listener subscribes and close it when the last one cancels. Every
/// listener gets what arrives after it subscribed. The streams never carry
/// errors: they complete when the port disappears, after the values they
/// still hold, and a loss shows on `Midi.diagnostics`.
///
/// Every event keeps the time the operating system received it at, also
/// when the app's isolate was busy.
final class MidiInput {
  MidiInput._(this._midi, this._info)
    : _events = _MidiInputFeed(_midi, _info.id, raw: false),
      _packets = _MidiInputFeed(_midi, _info.id, raw: true);

  // ...........................................................................
  /// Returns the events of the port decoded with [options] instead of the
  /// defaults of the engine, e.g. translated to MIDI 2.0 with
  /// `MidiInputOptions(deliverAs: MidiProtocol.midi2)`.
  ///
  /// Each call returns a stream of its own that opens the port like
  /// [messages] does.
  Stream<MidiEvent> messagesWith(MidiInputOptions options) =>
      _MidiInputFeed<MidiEvent>(_midi, id, raw: false, options: options).stream;

  /// Ends the streams of the port in this isolate and closes the port when
  /// no other isolate listens; a new listener opens it again.
  Future<void> close() async {
    await Future.wait([
      for (final feed in [..._midi._feedsOf(id)]) feed.end(),
    ]);
  }

  // ...........................................................................
  /// The description of the port; the last one known after the port
  /// disappeared.
  MidiPortInfo get info => _info;

  /// The id of the port.
  MidiPortId get id => _info.id;

  /// The messages of the port as events with their time, group and port,
  /// decoded with the defaults of the engine.
  Stream<MidiEvent> get messages => _events.stream;

  /// The raw packets of the port exactly as the operating system delivered
  /// them: MIDI 1.0 bytes, or UMP words for ports with
  /// [MidiPortCapabilities.ump].
  Stream<MidiPacket> get packets => _packets.stream;

  // ...........................................................................
  final Midi _midi;
  MidiPortInfo _info;
  final _MidiInputFeed<MidiEvent> _events;
  final _MidiInputFeed<MidiPacket> _packets;
}

// #############################################################################
/// One host stream of an input port, shared by the listeners of one stream
/// of a [MidiInput].
final class _MidiInputFeed<T> {
  _MidiInputFeed(this._midi, this._port, {required this.raw, this.options});

  // ...........................................................................
  /// Ends every listener and the host stream.
  Future<void> end() async {
    final listeners = [..._listeners];
    _listeners.clear();
    for (final listener in listeners) {
      listener.end();
    }
    await _stop();
  }

  // ...........................................................................
  /// The stream the listeners subscribe to.
  late final Stream<T> stream = Stream<T>.multi(_listen, isBroadcast: true);

  /// Whether the feed delivers raw packets instead of events.
  final bool raw;

  /// The options of the input session, or null for the engine's default.
  final MidiInputOptions? options;

  // ...........................................................................
  final Midi _midi;
  final MidiPortId _port;
  final _listeners = <_MidiListener<T>>[];
  int? _stream;

  /// The number of values a paused listener keeps.
  int get _capacity => (options ?? const MidiInputOptions()).queueCapacity;

  /// Adds the listener of [controller] and opens the host stream for the
  /// first.
  void _listen(MultiStreamController<T> controller) {
    if (_midi._closing != null || _midi._isClosed) {
      controller.closeSync();
      return;
    }
    final listener = _MidiListener<T>(controller, capacity: _capacity);
    _listeners.add(listener);
    controller
      ..onResume = (() => scheduleMicrotask(listener.flush))
      ..onCancel = (() => _remove(listener));
    if (_listeners.length == 1) _start();
  }

  /// Opens the host stream.
  void _start() {
    final id = _stream = _midi._nextStream++;
    _midi._feedsOf(_port).add(this);
    _midi._streams[id] = (add: _add, addError: null, done: () => _ended(id));
    unawaited(
      _midi
          ._request<void>(
            (request) => MidiOpenInputCommand(
              proxy: _midi._id,
              request: request,
              stream: id,
              port: _port,
              raw: raw,
              options: options,
            ),
          )
          .then((_) {}, onError: (Object error) => _failed(id, error)),
    );
  }

  /// Removes [listener] and closes the host stream after the last one.
  Future<void> _remove(_MidiListener<T> listener) async {
    _listeners.remove(listener);
    if (_listeners.isEmpty) await _stop();
  }

  /// Closes the host stream when it is open.
  Future<void> _stop() async {
    final id = _stream;
    if (id == null) return;
    _stream = null;
    _midi._feedsOf(_port).remove(this);
    await _midi._cancelStream(id);
  }

  /// Hands [values] to every listener and reports what paused listeners
  /// dropped.
  void _add(List<Object?> values) {
    var dropped = 0;
    for (final listener in [..._listeners]) {
      dropped += listener.add(values);
    }
    if (dropped == 0) return;
    _midi._report(
      MidiDiagnostic(
        kind: MidiDiagnosticKind.queueOverflow,
        port: _port,
        count: dropped,
        cause:
            'Paused listeners of $_port dropped $dropped '
            '${raw ? 'packets' : 'events'} beyond their capacity of '
            '$_capacity',
        time: _midi.now(),
      ),
    );
  }

  /// Ends the listeners after the host stream [id] ended, e.g. because the
  /// port disappeared.
  void _ended(int id) {
    if (_stream != id) return;
    _stream = null;
    _midi._feedsOf(_port).remove(this);
    final listeners = [..._listeners];
    _listeners.clear();
    for (final listener in listeners) {
      listener.end();
    }
  }

  /// Ends the listeners after the host stream [id] failed to open; a
  /// failure other than a vanished port becomes a diagnostic.
  void _failed(int id, Object error) {
    if (_stream != id) return;
    _midi._streams.remove(id);
    _ended(id);
    if (error is MidiPortGone) return;
    _midi._report(
      MidiDiagnostic(
        kind: MidiDiagnosticKind.nativeError,
        port: _port,
        cause: 'Opening the input failed: $error',
        time: _midi.now(),
      ),
    );
  }
}

// #############################################################################
/// A listener of an input stream; while it is paused, it keeps up to
/// [capacity] values and drops newer ones.
final class _MidiListener<T> {
  _MidiListener(this.controller, {required this.capacity});

  // ...........................................................................
  /// Delivers [values] or keeps them while paused; returns how many were
  /// dropped.
  int add(List<Object?> values) {
    var dropped = 0;
    for (final value in values) {
      if (!controller.hasListener) break;
      if (_waiting.isEmpty && !controller.isPaused) {
        controller.addSync(value as T);
      } else if (_waiting.length < capacity) {
        _waiting.add(value as T);
      } else {
        dropped++;
      }
    }
    return dropped;
  }

  /// Delivers the kept values while the listener is not paused.
  void flush() {
    while (_waiting.isNotEmpty && !controller.isPaused) {
      controller.addSync(_waiting.removeFirst());
    }
  }

  /// Hands the kept values to the controller and closes it, so that the
  /// listener gets them before the end.
  void end() {
    _waiting.forEach(controller.add);
    _waiting.clear();
    controller.closeSync();
  }

  // ...........................................................................
  /// The controller of the listener.
  final MultiStreamController<T> controller;

  /// How many values the listener keeps while it is paused.
  final int capacity;

  // ...........................................................................
  final _waiting = ListQueue<T>();
}
