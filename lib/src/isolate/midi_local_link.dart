// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'midi_host.dart';
import 'midi_host_command.dart';
import 'midi_host_notice.dart';
import 'midi_link.dart';

// #############################################################################
/// The link of a proxy to a host in the same isolate: in the browser, where
/// Web MIDI exists on the main thread only, and with
/// `MidiOptions.inIsolate`.
///
/// Commands and notices are handed over in microtasks, so that both sides
/// see the same order and the same asynchrony as with a MIDI isolate.
final class MidiLocalLink implements MidiLink {
  /// Creates the link to [host] that delivers the notices to [onNotice].
  MidiLocalLink({required this.host, required this.onNotice});

  // ...........................................................................
  @override
  void send(MidiHostCommand command) =>
      scheduleMicrotask(() => host.handle(command));

  /// Does nothing: a proxy cannot outlive an isolate it shares with its
  /// host.
  @override
  void watch({required int proxy}) {}

  @override
  void close() => _isClosed = true;

  // ...........................................................................
  /// The host in the same isolate.
  final MidiHost host;

  /// Receives the notices of the host.
  final MidiNoticeSink onNotice;

  @override
  MidiNoticeSink get sink => _deliver;

  /// Whether the link is closed.
  bool get isClosed => _isClosed;

  // ...........................................................................
  bool _isClosed = false;

  /// Hands [notice] to [onNotice] in a microtask unless the link closed.
  void _deliver(MidiHostNotice notice) => scheduleMicrotask(() {
    if (!_isClosed) onNotice(notice);
  });
}
