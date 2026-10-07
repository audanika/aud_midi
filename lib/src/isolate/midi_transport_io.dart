// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import '../api/midi_connector.dart';
import '../api/midi_options.dart';
import '../backend/midi_platform_backend_io.dart';
import 'midi_host_notice.dart';
import 'midi_isolate_launcher.dart';
import 'midi_link.dart';
import 'midi_port_link.dart';

// #############################################################################
/// Whether MIDI hosts run in isolates of their own here: yes, where
/// `dart:io` exists.
const bool midiIsolatesSupported = true;

// #############################################################################
/// Spawns a MIDI isolate with a host for [options] and returns its
/// connector; without a backend factory in [options] the host runs the
/// backend of the operating system.
Future<MidiConnector> midiSpawnHost(MidiOptions options) =>
    spawnMidiIsolate(options: options, platformBackend: midiPlatformBackend);

// #############################################################################
/// Returns the link to the host of [connector] in another isolate that
/// delivers the notices to [onNotice].
MidiLink midiRemoteLink({
  required MidiConnector connector,
  required MidiNoticeSink onNotice,
}) => MidiPortLink(connector: connector, onNotice: onNotice);
