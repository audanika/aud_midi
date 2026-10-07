// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_web/aud_midi_web.dart';

import '../api/midi_options.dart';

// #############################################################################
/// Returns the backend of the browser: Web MIDI, asking for System
/// Exclusive access when [MidiOptions.sysEx] is set.
MidiBackend midiPlatformBackend(MidiOptions options) =>
    WebMidiBackend(sysEx: options.sysEx);
