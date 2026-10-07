// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Selects how proxies reach their MIDI host: through a MIDI isolate where
/// `dart:io` exists, in the same isolate everywhere else.
library;

export 'midi_transport_none.dart' if (dart.library.io) 'midi_transport_io.dart';
