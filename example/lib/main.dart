// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi/aud_midi.dart';
import 'package:flutter/material.dart';

void main() => runApp(const MidiExampleApp());

// #############################################################################
/// Opens MIDI and shows ports, a monitor, a sender, virtual ports,
/// Bluetooth LE MIDI and the network session.
class MidiExampleApp extends StatefulWidget {
  /// Creates the app.
  const MidiExampleApp({super.key});

  @override
  State<MidiExampleApp> createState() => _MidiExampleAppState();
}

class _MidiExampleAppState extends State<MidiExampleApp> {
  Midi? _midi;
  Object? _error;
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _diagnostics = <MidiDiagnostic>[];

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final midi = await Midi.open(
        options: const MidiOptions(clientName: 'aud_midi example', sysEx: true),
      );
      if (!mounted) return unawaited(midi.close());
      _subscriptions
        ..add(midi.changes.listen((_) => setState(() {})))
        ..add(
          midi.diagnostics.listen(
            (diagnostic) => setState(() => _diagnostics.insert(0, diagnostic)),
          ),
        );
      setState(() => _midi = midi);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_midi?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final midi = _midi;
    return MaterialApp(
      title: 'aud_midi',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: midi == null
          ? Scaffold(
              body: Center(
                child: Text(_error == null ? 'Opening MIDI …' : '$_error'),
              ),
            )
          : _Home(midi: midi, diagnostics: _diagnostics),
    );
  }
}

// #############################################################################
class _Home extends StatelessWidget {
  const _Home({required this.midi, required this.diagnostics});

  final Midi midi;
  final List<MidiDiagnostic> diagnostics;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 6,
    child: Scaffold(
      appBar: AppBar(
        title: Text('aud_midi · ${midi.backendName}'),
        bottom: const TabBar(
          isScrollable: true,
          tabs: [
            Tab(text: 'Ports'),
            Tab(text: 'Monitor'),
            Tab(text: 'Send'),
            Tab(text: 'Virtual'),
            Tab(text: 'Bluetooth'),
            Tab(text: 'Network'),
          ],
        ),
      ),
      body: TabBarView(
        children: [
          _PortsPage(midi: midi, diagnostics: diagnostics),
          _MonitorPage(midi: midi),
          _SendPage(midi: midi),
          _VirtualPage(midi: midi),
          _BluetoothPage(midi: midi),
          _NetworkPage(midi: midi),
        ],
      ),
    ),
  );
}

// #############################################################################
class _PortsPage extends StatelessWidget {
  const _PortsPage({required this.midi, required this.diagnostics});

  final Midi midi;
  final List<MidiDiagnostic> diagnostics;

  @override
  Widget build(BuildContext context) {
    final capabilities = midi.capabilities;
    return ListView(
      children: [
        _Header('Inputs (${midi.inputs.length})'),
        for (final input in midi.inputs) _PortTile(input.info),
        _Header('Outputs (${midi.outputs.length})'),
        for (final output in midi.outputs) _PortTile(output.info),
        _Header('Devices (${midi.devices.length})'),
        for (final device in midi.devices)
          ListTile(
            title: Text(device.name),
            subtitle: Text(
              '${device.manufacturer} · ${device.transport.name} · '
              '${device.ports.length} ports',
            ),
          ),
        const _Header('Capabilities'),
        ListTile(
          title: Text(
            'virtual ports: ${capabilities.virtualPorts.name}, '
            'BLE: ${capabilities.bleScan}, UMP: ${capabilities.ump}, '
            'scheduling: ${capabilities.scheduling.name}',
          ),
          subtitle: Text(
            'network: ${capabilities.network.map((n) => n.name).join(', ')}'
            '${capabilities.missingPermissions.isEmpty ? '' : ' · missing: '
                      '${capabilities.missingPermissions.map((p) => p.name).join(', ')}'}',
          ),
        ),
        _Header('Diagnostics (${diagnostics.length})'),
        for (final diagnostic in diagnostics.take(50))
          ListTile(
            dense: true,
            title: Text('${diagnostic.kind.name} ×${diagnostic.count}'),
            subtitle: Text(diagnostic.cause),
          ),
      ],
    );
  }
}

class _PortTile extends StatelessWidget {
  const _PortTile(this.port);

  final MidiPortInfo port;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(port.isInput ? Icons.input : Icons.output),
    title: Text(port.name),
    subtitle: Text(
      '${port.transport.name} · ${port.protocol.name} · ${port.state.name}'
      '${port.isOwn ? ' · own' : ''}',
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

// #############################################################################
class _MonitorPage extends StatefulWidget {
  const _MonitorPage({required this.midi});

  final Midi midi;

  @override
  State<_MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<_MonitorPage> {
  final _events = <(String, MidiEvent)>[];
  final _subscriptions = <StreamSubscription<MidiEvent>>[];
  MidiPortId? _selected;

  void _listen(MidiPortId? id) {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final inputs = id == null ? widget.midi.inputs : [?widget.midi.input(id)];
    for (final input in inputs) {
      _subscriptions.add(
        input.messages.listen(
          (event) => setState(() {
            _events.insert(0, (input.info.name, event));
            if (_events.length > 200) _events.removeLast();
          }),
        ),
      );
    }
    setState(() => _selected = id);
  }

  @override
  void initState() {
    super.initState();
    _listen(null);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: DropdownButton<MidiPortId?>(
                isExpanded: true,
                value: _selected,
                items: [
                  const DropdownMenuItem(child: Text('All inputs')),
                  for (final input in widget.midi.inputs)
                    DropdownMenuItem(
                      value: input.id,
                      child: Text(input.info.name),
                    ),
                ],
                onChanged: _listen,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () => setState(_events.clear),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: _events.length,
          itemBuilder: (context, index) {
            final (port, event) = _events[index];
            return ListTile(
              dense: true,
              title: Text('${event.message}'),
              subtitle: Text(
                '$port · ${(event.time.microseconds / 1000).toStringAsFixed(3)}'
                ' ms',
              ),
            );
          },
        ),
      ),
    ],
  );
}

// #############################################################################
class _SendPage extends StatefulWidget {
  const _SendPage({required this.midi});

  final Midi midi;

  @override
  State<_SendPage> createState() => _SendPageState();
}

class _SendPageState extends State<_SendPage> {
  MidiPortId? _selected;
  double _note = 60;
  double _value = 64;
  String _status = '';

  MidiOutput? get _output =>
      _selected == null ? null : widget.midi.output(_selected!);

  Future<void> _run(
    String label,
    Future<void> Function(MidiOutput) send,
  ) async {
    final output = _output;
    if (output == null) return;
    try {
      await send(output);
      setState(() => _status = '$label sent to ${output.info.name}');
    } on Object catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = _note.round();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        DropdownButton<MidiPortId?>(
          isExpanded: true,
          hint: const Text('Choose an output'),
          value: _selected,
          items: [
            for (final output in widget.midi.outputs)
              DropdownMenuItem(value: output.id, child: Text(output.info.name)),
          ],
          onChanged: (id) => setState(() => _selected = id),
        ),
        Text('Note $note'),
        Slider(
          value: _note,
          max: 127,
          onChanged: (value) => setState(() => _note = value),
        ),
        Text('Value ${_value.round()}'),
        Slider(
          value: _value,
          max: 127,
          onChanged: (value) => setState(() => _value = value),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => _run('Note $note', (output) async {
                await output.send(
                  MidiNoteOn(channel: 0, note: note, velocity: 100),
                );
                await output.send(
                  MidiNoteOff(channel: 0, note: note),
                  at: widget.midi.now() + const Duration(milliseconds: 400),
                );
              }),
              child: const Text('Play note'),
            ),
            OutlinedButton(
              onPressed: () => _run(
                'CC 1',
                (output) => output.send(
                  MidiControlChange(
                    channel: 0,
                    controller: MidiControllers.modulationWheel,
                    value: _value.round(),
                  ),
                ),
              ),
              child: const Text('Modulation'),
            ),
            OutlinedButton(
              onPressed: () => _run(
                'Program',
                (output) => output.send(
                  MidiProgramChange(channel: 0, program: _value.round()),
                ),
              ),
              child: const Text('Program change'),
            ),
            OutlinedButton(
              onPressed: () => _run('Panic', (output) => output.panic()),
              child: const Text('Panic'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(_status),
      ],
    );
  }
}

// #############################################################################
class _VirtualPage extends StatefulWidget {
  const _VirtualPage({required this.midi});

  final Midi midi;

  @override
  State<_VirtualPage> createState() => _VirtualPageState();
}

class _VirtualPageState extends State<_VirtualPage> {
  final _name = TextEditingController(text: 'aud_midi example');
  String _status = '';

  Future<void> _run(Future<void> Function(MidiVirtualPorts) action) async {
    final virtualPorts = widget.midi.virtualPorts;
    if (virtualPorts == null) return;
    try {
      await action(virtualPorts);
      setState(() => _status = '');
    } on Object catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final virtualPorts = widget.midi.virtualPorts;
    if (virtualPorts == null) {
      return const Center(child: Text('No virtual ports on this platform'));
    }
    final own = widget.midi.ports.where((port) => port.isOwn).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () => _run((ports) => ports.createSource(_name.text)),
              child: const Text('Create source'),
            ),
            FilledButton(
              onPressed: () =>
                  _run((ports) => ports.createDestination(_name.text)),
              child: const Text('Create destination'),
            ),
          ],
        ),
        Text('Support: ${virtualPorts.support.name}  $_status'),
        const _Header('Own ports'),
        for (final port in own)
          ListTile(
            title: Text(port.name),
            subtitle: Text(port.isOutput ? 'source' : 'destination'),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _run((ports) => ports.remove(port.id)),
            ),
          ),
      ],
    );
  }
}

// #############################################################################
class _BluetoothPage extends StatefulWidget {
  const _BluetoothPage({required this.midi});

  final Midi midi;

  @override
  State<_BluetoothPage> createState() => _BluetoothPageState();
}

class _BluetoothPageState extends State<_BluetoothPage> {
  final _found = <String, MidiBlePeripheralInfo>{};
  StreamSubscription<MidiBlePeripheralInfo>? _scan;
  String _status = '';

  void _startScan(MidiBluetooth bluetooth) {
    unawaited(_scan?.cancel());
    setState(() => _status = 'Scanning …');
    _scan = bluetooth
        .scan(timeout: const Duration(seconds: 15))
        .listen(
          (peripheral) => setState(() => _found[peripheral.id] = peripheral),
          onError: (Object error) => setState(() => _status = '$error'),
          onDone: () => setState(() {
            _scan = null;
            if (_status == 'Scanning …') _status = '';
          }),
        );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      setState(() => _status = '');
    } on Object catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bluetooth = widget.midi.bluetooth;
    if (bluetooth == null) {
      return const Center(child: Text('No Bluetooth LE MIDI here'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: _scan == null ? () => _startScan(bluetooth) : null,
              child: const Text('Scan'),
            ),
            OutlinedButton(
              onPressed: _scan == null ? null : () => _run(bluetooth.stopScan),
              child: const Text('Stop'),
            ),
          ],
        ),
        Text(_status),
        for (final peripheral in _found.values)
          ListTile(
            title: Text(
              peripheral.name.isEmpty ? peripheral.id : peripheral.name,
            ),
            subtitle: Text('RSSI ${peripheral.rssi ?? '–'}'),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  icon: const Icon(Icons.link),
                  onPressed: () => _run(() async {
                    await bluetooth.connect(peripheral.id);
                  }),
                ),
                IconButton(
                  icon: const Icon(Icons.link_off),
                  onPressed: () =>
                      _run(() => bluetooth.disconnect(peripheral.id)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// #############################################################################
class _NetworkPage extends StatefulWidget {
  const _NetworkPage({required this.midi});

  final Midi midi;

  @override
  State<_NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<_NetworkPage> {
  final _name = TextEditingController(text: 'aud_midi example');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '5004');
  final _subscriptions = <StreamSubscription<Object?>>[];
  List<MidiNetworkHostInfo> _hosts = const [];
  String _status = '';

  @override
  void initState() {
    super.initState();
    final network = widget.midi.network;
    if (network == null) return;
    _subscriptions
      ..add(network.sessionChanges.listen((_) => setState(() {})))
      ..add(
        network.browse().listen(
          (hosts) => setState(() => _hosts = hosts),
          onError: (Object error) => setState(() => _status = '$error'),
        ),
      );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      setState(() => _status = '');
    } on Object catch (error) {
      setState(() => _status = '$error');
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _name.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final network = widget.midi.network;
    if (network == null) {
      return const Center(child: Text('No network session here'));
    }
    final session = network.session;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Session name'),
        ),
        SwitchListTile(
          title: Text(
            session.enabled
                ? '${session.localName} on port ${session.port}'
                : 'Session disabled',
          ),
          value: session.enabled,
          onChanged: (enabled) => _run(
            () async => enabled
                ? await network.enable(name: _name.text)
                : await network.disable(),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _host,
                decoration: const InputDecoration(labelText: 'Host'),
              ),
            ),
            SizedBox(
              width: 80,
              child: TextField(
                controller: _port,
                decoration: const InputDecoration(labelText: 'Port'),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.link),
              onPressed: () => _run(() async {
                await network.connect(_host.text, int.parse(_port.text));
              }),
            ),
          ],
        ),
        Text(_status),
        _Header('Connections (${session.connections.length})'),
        for (final connection in session.connections)
          ListTile(
            title: Text(connection.host.name),
            subtitle: Text(
              '${connection.host.address}:${connection.host.port} · '
              '${connection.state.name}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.link_off),
              onPressed: () => _run(() => network.disconnect(connection.host)),
            ),
          ),
        _Header('Sessions in the network (${_hosts.length})'),
        for (final host in _hosts)
          ListTile(
            title: Text(host.name),
            subtitle: Text('${host.address}:${host.port}'),
            trailing: IconButton(
              icon: const Icon(Icons.link),
              onPressed: () => _run(() async {
                await network.connectTo(host);
              }),
            ),
          ),
      ],
    );
  }
}
