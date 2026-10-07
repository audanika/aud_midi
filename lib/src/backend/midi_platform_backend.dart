// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Selects the backend of the platform: the backends of the operating
/// systems where `dart:io` exists, Web MIDI in the browser, none elsewhere.
library;

export 'midi_platform_backend_none.dart'
    if (dart.library.io) 'midi_platform_backend_io.dart'
    if (dart.library.js_interop) 'midi_platform_backend_web.dart';
