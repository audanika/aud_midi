# aud_midi

MIDI for Dart and Flutter apps on iOS, macOS, Android, Windows, Linux and
the web: USB, Bluetooth LE, virtual and network MIDI with MIDI 1.0 and
MIDI 2.0 (UMP) messages. All MIDI I/O runs in its own isolate, so a busy
app isolate never delays it. No platform channels: the backends talk to
the operating system through FFI, JNI and JS interop.

## Goals

- One API for six platforms; ports are the primary entity
- USB, Bluetooth LE, virtual ports and network sessions (AppleMIDI,
  Network MIDI 2.0)
- MIDI 1.0 and MIDI 2.0 messages with explicit translation
- Exact timing: OS timestamps on input, OS scheduling on output
- A MIDI isolate that the app's isolates cannot delay
- Losses are visible as diagnostics, streams never error

## State

| Platform | Backend | Verified in this ticket |
| --- | --- | --- |
| macOS | CoreMIDI (UMP), Bonjour, pure-Dart AppleMIDI | real loopback, example app build |
| iOS | CoreMIDI (UMP), `MIDINetworkSession` | simulator loopback, example app build |
| Android | `android.media.midi` + AMidi | emulator loopback, example APK build |
| Windows | WinRT MIDI, optional Windows MIDI Services | Dart logic only, not built on Windows |
| Linux | ALSA sequencer, BlueZ, Avahi | Dart logic only, not run on Linux |
| Web | Web MIDI | Chrome, example web build |

`midi_bench` on this Mac (Apple backend, two clean runs, 500 messages
each):

| Check | Median | p95 | p99 |
| --- | --- | --- | --- |
| Round trip through virtual endpoints to the app isolate | 152–158 µs | 228–249 µs | 378–384 µs |
| CoreMIDI-scheduled send with a busy app isolate, arrival − due | 62–63 µs | 133–138 µs | 164–726 µs |
| Software-scheduled send from an own virtual source, arrival − due | 2.5–2.6 ms | 3.2 ms | 3.3 ms |

Fragmented SysEx with clocks in between is reassembled, overflows are
fully accounted for by diagnostics, hotplug is reported after about
290 ms. Coverage of the package is 100 %.

## Installation

```yaml
dependencies:
  aud_midi:
    git:
      url: git@github.com:audmidi/aud_midi.git
```

The package depends on all backends; `aud_midi_android` needs the Flutter
SDK (`jni`), so use the `dart` of a Flutter installation.

Platform setup:

- iOS: `NSBluetoothAlwaysUsageDescription`,
  `NSLocalNetworkUsageDescription`, `NSBonjourServices`
  (`_apple-midi._udp`), `UIBackgroundModes` `audio` for virtual ports
  (and `bluetooth-central` for BLE in the background)
- macOS: entitlements `com.apple.security.device.bluetooth`,
  `com.apple.security.network.client`,
  `com.apple.security.network.server`
- Android: the permissions and services from the
  [aud_midi_android README](https://github.com/audmidi/aud_midi_android)
- Windows: MSIX capabilities `bluetooth`, `internetClient`,
  `privateNetworkClientServer`
- Linux: `libasound2`, access to `/dev/snd/seq`; BlueZ and Avahi over
  D-Bus for BLE and network
- Web: https or localhost, the browser's MIDI permission

The example app in `example/` shows these settings.

## Documentation

- [Architecture](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/architecture/architecture.md)
- [Plan](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md)
  and [decisions](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/concepts/decisions/000-index.md)
- Packages: [aud_midi_standard](https://github.com/audmidi/aud_midi_standard)
  (messages, codecs), [aud_midi_core](https://github.com/audmidi/aud_midi_core)
  (engine), the backends and [aud_midi_network](https://github.com/audmidi/aud_midi_network)
- Examples: `example/cli` (`aud_midi_cli`, `midi_bench`, `hello_midi`),
  `example/` (Flutter app)

## Code Examples

`example/cli/bin/hello_midi.dart`:

```dart
import 'package:aud_midi/aud_midi.dart';

Future<void> main() async {
  // Start the MIDI isolate with the backend of this platform
  final midi = await Midi.open();
  print('Backend: ${midi.backendName}');
  for (final input in midi.inputs) {
    print('Input:  ${input.info.name}');
  }
  for (final output in midi.outputs) {
    print('Output: ${output.info.name}');
  }

  // Create a virtual source that other apps can receive from
  final source = await midi.virtualPorts!.createSource('aud_midi hello');

  // Play C4 now and release it 500 ms later; the MIDI isolate schedules
  // the Note Off, so a busy app isolate cannot delay it
  await source.send(const MidiNoteOn(channel: 0, note: 60, velocity: 100));
  await source.send(
    const MidiNoteOff(channel: 0, note: 60),
    at: midi.now() + const Duration(milliseconds: 500),
  );
  await Future<void>.delayed(const Duration(seconds: 1));

  await midi.close();
}
```

## How It Works

`Midi.open()` spawns one MIDI isolate per process. It hosts a
`MidiEngine` from `aud_midi_core` with the backend of the platform,
composed with the network session and Bluetooth LE where needed. The
`Midi`, `MidiInput` and `MidiOutput` objects in the app are proxies that
talk to it through `SendPort`s; other isolates attach with
`Midi.attach(midi.connector)`. Scheduled sends reach the MIDI isolate at
once and are handed to the operating system 100 ms before they are due,
so they stay cancellable. On the web the engine runs on the main thread,
where Web MIDI lives.

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
