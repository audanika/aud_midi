// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import '../api/midi_connector.dart';
import '../api/midi_options.dart';
import 'midi_host_notice.dart';
import 'midi_link.dart';

// #############################################################################
/// Whether MIDI hosts run in isolates of their own here: no, e.g. in the
/// browser, where hosts run in the isolate of their proxies.
const bool midiIsolatesSupported = false;

// #############################################################################
/// Throws an [UnsupportedError]: there are no MIDI isolates here.
Future<MidiConnector> midiSpawnHost(MidiOptions options) =>
    throw UnsupportedError('MIDI isolates on this platform');

// #############################################################################
/// Throws an [UnsupportedError]: there are no MIDI isolates here.
MidiLink midiRemoteLink({
  required MidiConnector connector,
  required MidiNoticeSink onNotice,
}) => throw UnsupportedError('MIDI isolates on this platform');
