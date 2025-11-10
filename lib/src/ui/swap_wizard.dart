import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../localization/loc.dart';
import '../wallet/wallet_store.dart';

enum SwapMode { create, accept }

class SwapWizard extends StatefulWidget {
  const SwapWizard({super.key});

  @override
  State<SwapWizard> createState() => _SwapWizardState();
}

class _SwapWizardState extends State<SwapWizard> {
  late WalletStore store;

  SwapMode mode = SwapMode.create;
  int currentStep = 0;
  int? selectedSwapId;

  final fromAmountCtrl = TextEditingController(text: '100');
  final toAmountCtrl = TextEditingController(text: '0.00004');
  final timeoutCtrl = TextEditingController(text: '60');
  final importCtrl = TextEditingController();
  final hostCtrl = TextEditingController(text: '127.0.0.1');
  final portCtrl = TextEditingController(text: '80');

  @override
  void initState() {
    super.initState();
    importCtrl.addListener(() => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // kein unnötiges Listening
    store = context.read<WalletStore>();
  }

  @override
  void dispose() {
    fromAmountCtrl.dispose();
    toAmountCtrl.dispose();
    timeoutCtrl.dispose();
    importCtrl.dispose();
    hostCtrl.dispose();
    portCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          context.tr('Swap Wizard', 'Swap-Assistent'),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _buildModeSelector(context),
        const SizedBox(height: 20),
        _buildTimeline(context),
      ],
    );
  }

  Future<int?> _ensureSwapFromSlateAndReflectUI(Map<String, dynamic> slate) async {
  // kleine lokale Konverter (damit keine weiteren Helfer nötig sind)
  BigInt _asBigInt(dynamic v) {
    if (v is BigInt) return v;
    if (v is int) return BigInt.from(v);
    if (v is num) return BigInt.from(v);
    if (v is String) {
      final n = num.tryParse(v.trim());
      if (n != null) return BigInt.from(n);
    }
    return BigInt.zero;
  }

  int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  // mw/btc aus dem Slate lesen (robust gegen fehlende Keys)
  final mw  = (slate['mw']  is Map) ? Map<String, dynamic>.from(slate['mw'])  : const <String,dynamic>{};
  final btc = (slate['btc'] is Map) ? Map<String, dynamic>.from(slate['btc']) : const <String,dynamic>{};

  final mwAmount  = _asBigInt(mw['amount']);
  final btcAmount = _asBigInt(btc['amount']);
  final timeout   = _asInt(mw['timelock']) ?? _asInt(btc['timelock']) ?? 60;

  // UI-Felder aktualisieren (Komfort)
  if (mounted) {
    fromAmountCtrl.text = mwAmount.toString();
    toAmountCtrl.text   = btcAmount.toString();
    timeoutCtrl.text    = timeout.toString();
  }

  // Falls schon ein aktiver Swap existiert, den verwenden
  var id = _activeSwapId();
  if (id != null) return id;

  // Peer anwenden und neuen Swap erzeugen
  await _applyPeer();
  await store.createAtomicSwap(
    fromCurrency: 'GRIN',
    toCurrency: 'BTC',
    fromAmount: mwAmount,
    toAmount: btcAmount,
    timeoutMinutes: BigInt.from(timeout),
  );

  id = store.latestAtomicSwap?.id;

  if (mounted && id != null) {
    setState(() {
      selectedSwapId = id;
      if (currentStep < 1) currentStep = 1; // nach Erstellen zu „JSON teilen“
    });
  }
  return id;
}

  // ---------------- UI-Bausteine ----------------

  Widget _buildModeSelector(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: mode == SwapMode.create ? Colors.deepPurple : Colors.grey[800],
            ),
            onPressed: () => setState(() => mode = SwapMode.create),
            child: Text(context.tr('Angebot erstellen', 'Angebot erstellen')),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: mode == SwapMode.accept ? Colors.deepPurple : Colors.grey[800],
            ),
            onPressed: () => setState(() => mode = SwapMode.accept),
            child: Text(context.tr('Angebot akzeptieren', 'Angebot akzeptieren')),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeline(BuildContext context) {
    final steps = [
      _WizardStep(
        index: 0,
        label: context.tr('Step 1', 'Schritt 1'),
        title: mode == SwapMode.create
            ? context.tr('Angebot erstellen', 'Angebot erstellen')
            : context.tr('Slate importieren', 'Slate importieren'),
        icon: Icons.edit,
        description: mode == SwapMode.create
            ? context.tr(
                'Set amounts, timeout and peer details, then create the offer.',
                'Wähle Beträge, Timeout und Peer-Details, dann erstelle das Angebot.',
              )
            : context.tr(
                'Paste the partner slate JSON, configure the peer, and accept the swap.',
                'Füge das Partner-Slate-JSON ein, setze den Peer und akzeptiere den Swap.',
              ),
        content: mode == SwapMode.create ? _createPanel(context) : _importPanel(context),
      ),
      _WizardStep(
        index: 1,
        label: context.tr('Step 2', 'Schritt 2'),
        title: context.tr('JSON teilen', 'JSON teilen'),
        icon: Icons.share,
        description: context.tr(
          'Exportiere dein Public Slate bzw. kopiere das Partner-JSON.',
          'Exportiere dein Public Slate oder kopiere das Partner-JSON.',
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _exportEnabled() ? () => _exportSlate(context) : null,
              child: Text(context.tr('Public Slate exportieren', 'Public Slate exportieren')),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'Copy the slate JSON and send it to your counterparty via clipboard or chat.',
                'Kopiere das Slate-JSON und teile es per Zwischenablage oder Chat mit deinem Gegenüber.',
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      _WizardStep(
        index: 2,
        label: context.tr('Step 3', 'Schritt 3'),
        title: context.tr('On-chain', 'On-chain'),
        icon: Icons.lock,
        description: context.tr(
          'Sperren, Ausführen oder Abbrechen per Button.',
          'Sperren, Ausführen oder Abbrechen per Button.',
        ),
        content: Column(
          children: [
            _swapListCard(),
            const SizedBox(height: 12),
            _actionButtons(),
          ],
        ),
      ),
    ];

    return Column(children: steps.map((s) => _buildStepCard(s, context)).toList());
  }

  Widget _buildStepCard(_WizardStep step, BuildContext context) {
    final completed = step.index < currentStep;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: completed ? Colors.green : Colors.deepPurple,
                  child: Icon(step.icon, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('${step.label} • ${step.title}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Text(completed ? context.tr('Erledigt', 'Erledigt') : ''),
              ],
            ),
            const SizedBox(height: 12),
            Text(step.description, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            step.content,
          ],
        ),
      ),
    );
  }

  Widget _createPanel(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _numberField(context.tr('From GRIN', 'Von GRIN'), fromAmountCtrl),
        const SizedBox(height: 8),
        _numberField(context.tr('To BTC', 'Zu BTC'), toAmountCtrl),
        const SizedBox(height: 8),
        _numberField(context.tr('Timeout (min)', 'Timeout (Min)'), timeoutCtrl),
        const SizedBox(height: 16),
        _connectionCard(context),
        const SizedBox(height: 8),
        _storageInfo(context),
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _createSwap,
          child: Text(context.tr('Swap erstellen', 'Swap erstellen')),
        ),
      ],
    );
  }

  Widget _importPanel(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: importCtrl,
          minLines: 3,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: context.tr('Partner-Slate JSON', 'Partner-Slate JSON'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        _connectionCard(context),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: _canImportAccept() ? _importSlate : null,
          child: Text(context.tr('Importieren & akzeptieren', 'Importieren & akzeptieren')),
        ),
        const SizedBox(height: 8),
        _storageInfo(context),
      ],
    );
  }

  Widget _connectionCard(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _simpleField(context.tr('Host', 'Host'), hostCtrl)),
            const SizedBox(width: 8),
            SizedBox(width: 90, child: _simpleField(context.tr('Port', 'Port'), portCtrl)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'The peer host/port is attached automatically when creating or accepting swaps.',
            'Host/Port werden beim Erstellen oder Akzeptieren automatisch übernommen.',
          ),
          style: const TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Widget _storageInfo(BuildContext context) {
    final label = _walletStorageLabel();
    final path = store.atomicSwapDirectory;
    return Row(
      children: [
        const Icon(Icons.storage, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.tr('Active wallet', 'Aktives Wallet'), style: const TextStyle(fontSize: 12, color: Colors.grey)),
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(path, style: const TextStyle(fontSize: 11, color: Colors.black54)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _swapListCard() {
    final swaps = store.atomicSwaps;
    if (swaps.isEmpty) {
      return Text(context.tr('Keine Swaps vorhanden', 'Keine Swaps vorhanden'));
    }
    return Column(
      children: swaps
          .map(
            (swap) => ListTile(
              title: Text('${context.tr('Swap', 'Swap')} ${swap.id}'),
              subtitle: Text(swap.status),
              selected: selectedSwapId == swap.id,
              onTap: () => setState(() => selectedSwapId = swap.id),
            ),
          )
          .toList(),
    );
  }

  Widget _numberField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }

  Widget _simpleField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }

  Widget _actionButtons() {
    final id = _activeSwapId();
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: id == null ? null : () => store.lockAtomicSwap(id),
                child: Text(context.tr('Lock', 'Lock')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                onPressed: id == null ? null : () => store.executeAtomicSwap(id),
                child: Text(context.tr('Execute', 'Execute')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: id == null ? null : () => store.cancelAtomicSwap(id),
                child: Text(context.tr('Cancel', 'Cancel')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: id == null ? null : () => store.deleteAtomicSwap(id),
                child: Text(context.tr('Delete', 'Delete')),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------- Actions ----------------

  bool _exportEnabled() => _activeSwapId() != null;

  Future<void> _createSwap() async {
    final from = _decimal(fromAmountCtrl.text);
    final to = _decimal(toAmountCtrl.text);
    final timeout = int.tryParse(timeoutCtrl.text.trim()) ?? 0;

    if (from == null || to == null || timeout <= 0) {
      _notify(context.trNow('Bitte gültige Beträge/Timeout eingeben.', 'Bitte gültige Beträge/Timeout eingeben.'));
      return;
    }

    await _applyPeer();

    try {
      await store.createAtomicSwap(
        fromCurrency: 'GRIN',
        toCurrency: 'BTC',
        fromAmount: from,
        toAmount: to,
        timeoutMinutes: BigInt.from(timeout),
      );

      final id = store.latestAtomicSwap?.id;

      if (!mounted) return;
      setState(() {
        currentStep = 1; // nach Erstellen zu „JSON teilen“
        selectedSwapId = id ?? selectedSwapId;
      });

      _notify(
        id != null ? context.trNow('Swap $id erstellt.', 'Swap $id erstellt.')
                    : context.trNow('Swap erstellt.', 'Swap erstellt.'),
      );
    } catch (e) {
      _notify('${context.trNow('Fehler', 'Fehler')}: $e');
    }
  }

  Future<void> _importSlate() async {
    final raw = importCtrl.text.trim();
    if (raw.isEmpty) {
      _notify(context.trNow('Bitte JSON eingeben.', 'Bitte JSON eingeben.'));
      return;
    }

    final parsed = _extractSwapIdAndPayload(raw);
    if (parsed == null) {
      _notify(context.trNow(
        'Ungueltiges JSON. Erwartet SwapSlatePub oder {id, pub_slate}.',
        'Ungueltiges JSON. Erwartet SwapSlatePub oder {id, pub_slate}.',
      ));
      return;
    }

    // pub_slate → Map (für Auto-Create & UI-Refresh)
    Map<String, dynamic> slate;
    try {
      final tmp = jsonDecode(parsed.pubSlateJson);
      if (tmp is! Map<String, dynamic>) throw const FormatException('pub_slate not a map');
      slate = tmp;
    } catch (e) {
      _notify('${context.trNow('Fehler', 'Fehler')}: $e');
      return;
    }

    // 1) Wrapper-ID nur verwenden, wenn sie lokal existiert
    int? swapId = parsed.swapId;
    if (swapId != null && !_swapExistsLocally(swapId)) {
      swapId = null; // lokal unbekannt → wie Import ohne ID behandeln
    }

    // 2) Falls keine (lokale) ID vorhanden → automatisch anlegen und UI spiegeln
    swapId ??= _activeSwapId() ?? await _ensureSwapFromSlateAndReflectUI(slate);
    if (swapId == null) {
      _notify(context.trNow('Swap konnte nicht automatisch erstellt werden.', 'Swap konnte nicht automatisch erstellt werden.'));
      return;
    }

    try {
      await _applyPeer();
      await store.importAtomicSwap(swapId, parsed.pubSlateJson);
      await store.acceptAtomicSwap(swapId);

      if (!mounted) return;
      setState(() {
        currentStep = 2;
        selectedSwapId = store.latestAtomicSwap?.id ?? swapId;
      });

      _notify(context.trNow('Import und Akzeptieren erfolgreich.', 'Import und Akzeptieren erfolgreich.'));
    } catch (e) {
      _notify('${context.trNow('Fehler', 'Fehler')}: $e');
    }
  }

  Future<void> _exportSlate(BuildContext context) async {
    final id = _activeSwapId();
    if (id == null) return;
    final payload = await store.fetchAtomicSwapPayload(id);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Exported Slate', 'Exportiertes Slate')),
        content: SelectableText(payload),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: payload));
              Navigator.of(context).pop();
            },
            child: Text(context.tr('Copy', 'Kopieren')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.tr('Close', 'Schließen')),
          ),
        ],
      ),
    );
  }

  Future<void> _applyPeer() async {
    await store.setAtomicSwapPeer(hostCtrl.text.trim(), portCtrl.text.trim());
  }

  bool _canImportAccept() {
    final raw = importCtrl.text.trim();
    // Button nur deaktivieren, wenn leer oder Busy. Keine Snackbars hier!
    return raw.isNotEmpty && !store.atomicSwapBusy;
  }

  void _notify(String message) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  // ---------------- Helpers ----------------

  int? _activeSwapId() => selectedSwapId ?? store.latestAtomicSwap?.id;

  BigInt? _decimal(String raw) {
    final cleaned = raw.replaceAll(RegExp('[^0-9]'), '');
    if (cleaned.isEmpty) return null;
    return BigInt.parse(cleaned);
  }

  String _walletStorageLabel() {
    final raw = store.atomicSwapDirectory;
    final segments = raw.split(RegExp(r'[\\/]+')).where((p) => p.isNotEmpty).toList();
    if (segments.isNotEmpty) return segments.first;
    return raw;
  }

  bool _swapExistsLocally(int id) {
    try {
      return store.atomicSwaps.any((s) => s.id == id);
    } catch (_) {
      return false;
    }
  }

  int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  BigInt _asBigInt(dynamic v) {
    if (v is BigInt) return v;
    if (v is int) return BigInt.from(v);
    if (v is num) return BigInt.from(v); // Dezimal → abgerundet
    if (v is String) {
      final n = num.tryParse(v.trim());
      if (n != null) return BigInt.from(n);
    }
    return BigInt.zero;
  }

  dynamic _jsonDecodeTolerant(String s) {
    final cleaned = s.trim().replaceAll('\u2028', '').replaceAll('\u2029', '');
    try {
      final first = jsonDecode(cleaned);

      // JSON als String (doppelt serialisiert)?
      if (first is String) {
        return jsonDecode(first);
      }

      // Ein-Element-Array?
      if (first is List && first.length == 1 && first.first is Map) {
        return first.first;
      }

      return first;
    } catch (_) {
      // Falls mit Anführungszeichen umschlossen
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        try {
          return jsonDecode(jsonDecode(cleaned));
        } catch (_) {}
      }
      return null;
    }
  }

  _ImportData? _extractSwapIdAndPayload(String raw) {
    try {
      final decoded = _jsonDecodeTolerant(raw);
      if (decoded is! Map) return null;
      final Map<String, dynamic> obj = Map<String, dynamic>.from(decoded);

      // A) Wrapper: { id, pub_slate [, checksum] }
      if (obj.containsKey('id') && obj.containsKey('pub_slate')) {
        final idVal = obj['id'];
        final swapId = (idVal is int)
            ? idVal
            : (idVal is String ? int.tryParse(idVal) : (idVal is num ? idVal.toInt() : null));

        dynamic ps = obj['pub_slate'];
        if (ps is String) {
          final inner = _jsonDecodeTolerant(ps);
          if (inner is Map) ps = inner;
        }
        if (swapId != null && ps is Map) {
          final Map<String, dynamic> map = Map<String, dynamic>.from(ps);
          // meta.port → int normalisieren
          if (map['meta'] is Map) {
            final meta = Map<String, dynamic>.from(map['meta']);
            final p = _asInt(meta['port']);
            if (p != null) meta['port'] = p;
            map['meta'] = meta;
          }
          return _ImportData(swapId: swapId, pubSlateJson: jsonEncode(map));
        }
      }

      // B) Raw SwapSlatePub: { status, mw, btc [, meta] }
      final hasKeys = obj.containsKey('status') && obj.containsKey('mw') && obj.containsKey('btc');
      if (hasKeys) {
        if (obj['meta'] is Map) {
          final meta = Map<String, dynamic>.from(obj['meta']);
          final p = _asInt(meta['port']);
          if (p != null) meta['port'] = p; // "80" → 80
          obj['meta'] = meta;
        }
        return _ImportData(swapId: null, pubSlateJson: jsonEncode(obj));
      }
    } catch (e) {
      debugPrint('JSON parse error: $e');
    }
    return null;
  }
}

// ---------------- Models ----------------

class _ImportData {
  _ImportData({required this.swapId, required this.pubSlateJson});
  final int? swapId;
  final String pubSlateJson;
}

class _WizardStep {
  final int index;
  final String label;
  final String title;
  final String description;
  final IconData icon;
  final Widget content;

  _WizardStep({
    required this.index,
    required this.label,
    required this.title,
    required this.description,
    required this.icon,
    required this.content,
  });
}
