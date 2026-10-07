// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'midi_host_notice.dart';

// #############################################################################
/// A request of a proxy to its MIDI host.
///
/// The host answers every command with a [MidiReplyNotice] or a
/// [MidiFailureNotice] for [request]. Commands of one proxy are handled in
/// the order they were sent; a command that waits, e.g. for a port to open,
/// holds back the later commands of the same output only.
sealed class MidiHostCommand {
  /// Creates the command [request] of the proxy [proxy].
  const MidiHostCommand({required this.proxy, required this.request});

  // ...........................................................................
  /// The id the host gave the proxy; 0 before the host answered the
  /// [MidiHelloCommand].
  final int proxy;

  /// The id of the request, unique per proxy.
  final int request;
}

// #############################################################################
/// Registers a proxy whose notices go to [sink]; the answer is a
/// `MidiHostSnapshot`.
final class MidiHelloCommand extends MidiHostCommand {
  /// Creates the registration [request] with [sink].
  const MidiHelloCommand({
    super.proxy = 0,
    required super.request,
    required this.sink,
  });

  // ...........................................................................
  /// Receives the notices of the proxy.
  final MidiNoticeSink sink;
}

// #############################################################################
/// Unregisters a proxy: its streams end, its outputs close and the host
/// shuts down after the last proxy. The answer is whether the host shut
/// down.
final class MidiGoodbyeCommand extends MidiHostCommand {
  /// Creates the unregistration [request] of [proxy].
  const MidiGoodbyeCommand({required super.proxy, required super.request});
}

// #############################################################################
/// A command of a registered proxy that the host serves while the proxy is
/// registered: everything but [MidiHelloCommand] and [MidiGoodbyeCommand].
sealed class MidiHostRequest extends MidiHostCommand {
  /// Creates the request [request] of the proxy [proxy].
  const MidiHostRequest({required super.proxy, required super.request});
}

// #############################################################################
/// Starts the host stream [stream] with the events of the input [port], or
/// with its raw packets when [raw] is set.
final class MidiOpenInputCommand extends MidiHostRequest {
  /// Creates the command.
  ///
  /// - [options] the options of the input session, null for the engine's
  ///   default.
  const MidiOpenInputCommand({
    required super.proxy,
    required super.request,
    required this.stream,
    required this.port,
    required this.raw,
    this.options,
  });

  // ...........................................................................
  /// The id the proxy gives the stream.
  final int stream;

  /// The input port.
  final MidiPortId port;

  /// Whether the stream delivers raw packets instead of events.
  final bool raw;

  /// The options of the input session, or null for the engine's default.
  final MidiInputOptions? options;
}

// #############################################################################
/// Starts the host stream [stream] with the peripherals a Bluetooth LE MIDI
/// scan finds.
final class MidiScanCommand extends MidiHostRequest {
  /// Creates the command; the scan ends after [timeout] when it is set.
  const MidiScanCommand({
    required super.proxy,
    required super.request,
    required this.stream,
    this.timeout,
  });

  // ...........................................................................
  /// The id the proxy gives the stream.
  final int stream;

  /// How long the scan runs, or null until it is stopped.
  final Duration? timeout;
}

// #############################################################################
/// Starts the host stream [stream] with the hosts the network session finds
/// in the local network.
final class MidiBrowseCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiBrowseCommand({
    required super.proxy,
    required super.request,
    required this.stream,
  });

  // ...........................................................................
  /// The id the proxy gives the stream.
  final int stream;
}

// #############################################################################
/// Ends the host stream [stream]; an input closes its session.
final class MidiCancelStreamCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiCancelStreamCommand({
    required super.proxy,
    required super.request,
    required this.stream,
  });

  // ...........................................................................
  /// The id the proxy gave the stream.
  final int stream;
}

// #############################################################################
/// Sends [messages] in one packet to the output [port] at [at] on [group].
final class MidiSendCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiSendCommand({
    required super.proxy,
    required super.request,
    required this.port,
    required this.messages,
    this.at,
    this.group,
  });

  // ...........................................................................
  /// The output port.
  final MidiPortId port;

  /// The messages.
  final List<MidiMessage> messages;

  /// The due time, or null for now.
  final MidiTime? at;

  /// The group of a UMP port, or null for the port's group.
  final int? group;
}

// #############################################################################
/// Sends the raw [packet] to the output [port] at its time.
final class MidiSendPacketCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiSendPacketCommand({
    required super.proxy,
    required super.request,
    required this.port,
    required this.packet,
  });

  // ...........................................................................
  /// The output port.
  final MidiPortId port;

  /// The packet with its due time.
  final MidiPacket packet;
}

// #############################################################################
/// Discards the pending messages of the output [port]; the answer is the
/// number of messages that still leave.
final class MidiCancelPendingCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiCancelPendingCommand({
    required super.proxy,
    required super.request,
    required this.port,
  });

  // ...........................................................................
  /// The output port.
  final MidiPortId port;
}

// #############################################################################
/// Silences the output [port] as [panic] describes.
final class MidiOutputPanicCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiOutputPanicCommand({
    required super.proxy,
    required super.request,
    required this.port,
    required this.panic,
  });

  // ...........................................................................
  /// The output port.
  final MidiPortId port;

  /// What the panic sends.
  final MidiPanic panic;
}

// #############################################################################
/// Closes the output session of the proxy on [port].
final class MidiCloseOutputCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiCloseOutputCommand({
    required super.proxy,
    required super.request,
    required this.port,
  });

  // ...........................................................................
  /// The output port.
  final MidiPortId port;
}

// #############################################################################
/// Silences every open output of the host as [panic] describes.
final class MidiPanicCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiPanicCommand({
    required super.proxy,
    required super.request,
    required this.panic,
  });

  // ...........................................................................
  /// What the panic sends.
  final MidiPanic panic;
}

// #############################################################################
/// Asks for the diagnostic counters of the engine; the answer is a
/// `MidiDiagnosticsSnapshot`.
final class MidiDiagnosticsCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiDiagnosticsCommand({required super.proxy, required super.request});
}

// #############################################################################
/// Runs [action] with the backend inside the MIDI isolate; the answer is
/// its result.
final class MidiWithBackendCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiWithBackendCommand({
    required super.proxy,
    required super.request,
    required this.action,
  });

  // ...........................................................................
  /// The function to run with the backend.
  final FutureOr<Object?> Function(MidiBackend backend) action;
}

// #############################################################################
/// Creates the virtual port [spec] describes; the answer is the port.
final class MidiCreateVirtualPortCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiCreateVirtualPortCommand({
    required super.proxy,
    required super.request,
    required this.spec,
  });

  // ...........................................................................
  /// The description of the port.
  final MidiVirtualPortSpec spec;
}

// #############################################################################
/// Removes the own virtual [port].
final class MidiRemoveVirtualPortCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiRemoveVirtualPortCommand({
    required super.proxy,
    required super.request,
    required this.port,
  });

  // ...........................................................................
  /// The virtual port.
  final MidiPortId port;
}

// #############################################################################
/// Stops the running Bluetooth LE MIDI scans.
final class MidiStopScanCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiStopScanCommand({required super.proxy, required super.request});
}

// #############################################################################
/// Connects the Bluetooth LE MIDI [peripheral]; the answer is its ports.
final class MidiConnectPeripheralCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiConnectPeripheralCommand({
    required super.proxy,
    required super.request,
    required this.peripheral,
    required this.timeout,
  });

  // ...........................................................................
  /// The id of the peripheral.
  final String peripheral;

  /// How long the connection may take.
  final Duration timeout;
}

// #############################################################################
/// Disconnects the Bluetooth LE MIDI [peripheral].
final class MidiDisconnectPeripheralCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiDisconnectPeripheralCommand({
    required super.proxy,
    required super.request,
    required this.peripheral,
  });

  // ...........................................................................
  /// The id of the peripheral.
  final String peripheral;
}

// #############################################################################
/// Enables the network session; the answer is its state.
final class MidiEnableNetworkCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiEnableNetworkCommand({
    required super.proxy,
    required super.request,
    required this.name,
    required this.policy,
    this.port,
  });

  // ...........................................................................
  /// The name the session is advertised under.
  final String name;

  /// Who may connect.
  final MidiNetworkConnectionPolicy policy;

  /// The UDP port, or null for the default of the protocol.
  final int? port;
}

// #############################################################################
/// Disables the network session.
final class MidiDisableNetworkCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiDisableNetworkCommand({
    required super.proxy,
    required super.request,
  });
}

// #############################################################################
/// Connects the network session to [host]; the answer is the connection.
final class MidiConnectHostCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiConnectHostCommand({
    required super.proxy,
    required super.request,
    required this.host,
  });

  // ...........................................................................
  /// The remote session.
  final MidiNetworkHostInfo host;
}

// #############################################################################
/// Ends the connection of the network session to [host].
final class MidiDisconnectHostCommand extends MidiHostRequest {
  /// Creates the command.
  const MidiDisconnectHostCommand({
    required super.proxy,
    required super.request,
    required this.host,
  });

  // ...........................................................................
  /// The remote session.
  final MidiNetworkHostInfo host;
}
