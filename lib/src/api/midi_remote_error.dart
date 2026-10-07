// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// An error of the MIDI isolate that could not travel to the isolate of the
/// proxy as it was, e.g. because it holds a native resource.
///
/// Errors that can travel, among them every `MidiException`, arrive
/// unchanged; this one only keeps the type and the text of the original.
final class MidiRemoteError implements Exception {
  /// Creates the stand-in for an error of [type] described by [message].
  const MidiRemoteError({required this.type, required this.message});

  // ...........................................................................
  /// The runtime type of the original error.
  final String type;

  /// The text of the original error.
  final String message;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiRemoteError &&
          other.type == type &&
          other.message == message;

  @override
  int get hashCode => Object.hash(type, message);

  @override
  String toString() => 'MidiRemoteError($type): $message';
}
