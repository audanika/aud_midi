// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';

// #############################################################################
/// An advertiser that creates the real one at the first registration.
///
/// Some registrars touch the operating system when they are created, e.g.
/// `NsdManager` through JNI or `DnsServiceRegister` through a native
/// callback; behind this advertiser they are created only when a network
/// session is announced, in the MIDI isolate that announces it.
final class MidiLazyServiceAdvertiser implements MidiServiceAdvertiser {
  /// Creates an advertiser that calls [create] at the first registration.
  MidiLazyServiceAdvertiser(this.create);

  // ...........................................................................
  /// Registers the service at the real advertiser, which is created first
  /// when needed.
  @override
  Future<MidiServiceRegistration> register({
    required String name,
    required String type,
    required int port,
    Map<String, String> txt = const {},
  }) => (_advertiser ??= create()).register(
    name: name,
    type: type,
    port: port,
    txt: txt,
  );

  // ...........................................................................
  /// Creates the real advertiser.
  final MidiServiceAdvertiser Function() create;

  /// Whether the real advertiser was created.
  bool get isCreated => _advertiser != null;

  // ...........................................................................
  MidiServiceAdvertiser? _advertiser;
}
