// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';

import '../api/midi_options.dart';

// #############################################################################
/// Throws a [MidiUnsupported]: the platform has neither `dart:io` nor a
/// browser, so no backend can reach MIDI there.
MidiBackend midiPlatformBackend(MidiOptions options) =>
    throw const MidiUnsupported('MIDI on this platform');
