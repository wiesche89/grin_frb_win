import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../localization/loc.dart';
import '../localization/locale_store.dart';
import '../rust/frb_generated.dart/api.dart' as bridge;
import '../ui/swap_wizard.dart';
import '../wallet/models.dart';
import '../wallet/wallet_store.dart';

const _publicNode = 'https://grincoin.org';
const _localNode = 'http://localhost:3413';

enum WalletPanel { overview, transactions, outputs, slatepacks, swaps, accounts, tor, api }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _sendAccent = Color(0xFFff5f66);
  static const _receiveAccent = Color(0xFF43e99b);

  final nodeCtrl = TextEditingController(text: _publicNode);
  final dataDirCtrl = TextEditingController(text: 'wallet_data');
  final passCtrl = TextEditingController();
  final sendAmountCtrl = TextEditingController(text: '0.01');
  final sendAddressCtrl = TextEditingController();
  final incomingSlateCtrl = TextEditingController();
  final accountNameCtrl = TextEditingController();
  final proofTxCtrl = TextEditingController();
  final verifyProofCtrl = TextEditingController();
  final scanStartCtrl = TextEditingController();
  final scanBackCtrl = TextEditingController();
  final ScrollController _logScrollCtrl = ScrollController();

  String log = '';
  String? _walletPass;
  bool fluffTx = false;
  bool deleteUnconfirmed = false;
  WalletPanel panel = WalletPanel.overview;
  WalletStore? _walletStore;
  bool _bootstrapped = false;
  bool _fullSyncInProgress = false;

  @override
  void initState() {
    super.initState();
    incomingSlateCtrl.addListener(() => setState(() {}));
    // defer bootstrap until first build/mounted
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapIfNeeded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _walletStore ??= Provider.of<WalletStore>(context, listen: false);
    _bootstrapIfNeeded();
  }

  void _bootstrapIfNeeded() {
    if (_bootstrapped || !mounted) return;
    final store = _walletStore;
    if (store == null) return;
    _bootstrapped = true;
    // run without awaiting to avoid build-time provider errors
    scheduleMicrotask(() => store.bootstrap(defaultNode: _publicNode));
  }

  @override
  void dispose() {
    nodeCtrl.dispose();
    dataDirCtrl.dispose();
    passCtrl.dispose();
    sendAmountCtrl.dispose();
    sendAddressCtrl.dispose();
    incomingSlateCtrl.dispose();
    accountNameCtrl.dispose();
    proofTxCtrl.dispose();
    verifyProofCtrl.dispose();
    scanStartCtrl.dispose();
    scanBackCtrl.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  void append(String msg) {
    final stamp =
        DateTime.now().toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first;
    setState(() => log = '$stamp  $msg\n$log');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollCtrl.hasClients) {
        _logScrollCtrl.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _setNode(String url) async {
    final clean = url.trim();
    if (clean.isEmpty) {
      append('Please provide a node URL.');
      return;
    }
    final store = _walletStore;
    if (store == null) return;
    await store.updateNode(clean);
    append('Node set to $clean');
  }

  Future<void> _unlock({required bool create, String? overridePass}) async {
    final dirRaw = dataDirCtrl.text.trim();
    final walletStore = _walletStore;
    if (dirRaw.isEmpty || walletStore == null) {
      append('Directory required.');
      return;
    }
    final userPass = overridePass ?? passCtrl.text;
    final hasUserPass = userPass.trim().isNotEmpty;
    final dir = Directory(dirRaw).absolute.path;
    final dirExists = Directory(dir).existsSync();

    if (!create && !dirExists) {
      append('Wallet not found at $dir. Use "Create & unlock" for a new wallet.');
      return;
    }
    if (create && dirExists) {
      append('Wallet already exists at $dir. Choose a different directory or unlock it instead.');
      return;
    }
    final passToUse = hasUserPass ? userPass : (create ? '' : 'test'); // legacy fallback
    if (!hasUserPass && !create) {
      append('No passphrase entered, trying legacy default "test".');
    }
    try {
      await _blockingTask(
        context.trNow('Preparing wallet...', 'Wallet wird vorbereitet...'),
        () async {
          if (create) {
            await bridge.walletCreate(
              dataDir: dir,
              passphrase: passToUse,
              mnemonicLength: BigInt.from(24),
            );
          }
          await bridge.walletInitOrOpen(dataDir: dir, passphrase: passToUse);
        },
      );
      _walletPass = passToUse;
      await walletStore.onWalletUnlocked();
      append('Wallet unlocked. Run a full sync when needed.');
      await _checkForeignListener(dir);
    } catch (e) {
      append('Unlock failed: $e');
    }
  }

  Future<void> _runFullSync() async {
    if (_fullSyncInProgress) return;
    setState(() => _fullSyncInProgress = true);
    try {
      await _blockingTask(
        context.trNow(
          'Running full sync, please wait...',
          'Voller Sync laeuft, bitte warten...',
        ),
        () async => bridge.walletSync(),
      );
      final store = _walletStore;
      if (store != null) {
        await store.refreshAll();
      }
      append('Full sync finished.');
    } catch (e) {
      append('Full sync failed: $e');
    } finally {
      if (mounted) {
        setState(() => _fullSyncInProgress = false);
      } else {
        _fullSyncInProgress = false;
      }
    }
  }

  Future<void> _blockingTask(String message, Future<void> Function() run) async {
    final nav = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BlockingDialog(message: message),
    );
    try {
      await run();
    } finally {
      nav.pop();
    }
  }

  bool _canCancelTx(TransactionModel tx) {
    if (tx.confirmed) return false;
    if (tx.confirmations > 0) return false;
    final lowerDir = tx.direction.toLowerCase();
    final lowerStatus = tx.status.toLowerCase();
    if (lowerStatus.contains('cancel') ||
        lowerStatus.contains('reverted') ||
        lowerStatus.contains('pool') ||
        lowerStatus.contains('post')) {
      return false;
    }
    return lowerDir.contains('send') || lowerDir.contains('sent') || lowerDir.contains('spend');
  }

  Future<void> _confirmCancelTx(WalletStore store, TransactionModel tx) async {
    final shouldCancel = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(context.tr('Cancel transaction?', 'Transaktion abbrechen?')),
        content: Text(
          context.tr(
            'This will unlock the funds from Tx ${tx.id}. Continue?',
            'Dadurch werden die Mittel aus Tx ${tx.id} wieder freigegeben. Fortfahren?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(context.tr('No', 'Nein')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(context.tr('Yes, cancel', 'Ja, abbrechen')),
          ),
        ],
      ),
    );
    if (shouldCancel != true) return;
    try {
      await store.cancelTx(tx.id);
      append('Transaction ${tx.id} canceled.');
    } catch (e) {
      append('Cancel failed: $e');
    }
  }

  BigInt _parseAmount(String raw) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty) throw const FormatException('Amount missing');
    final isNano = trimmed.endsWith('n');
    final value = isNano ? trimmed.substring(0, trimmed.length - 1).trim() : trimmed;
    if (value.isEmpty) throw const FormatException('Amount missing');
    if (isNano) {
      if (!RegExp(r'^\d+$').hasMatch(value)) {
        throw const FormatException('Invalid nano amount');
      }
      return BigInt.parse(value);
    }
    final cleaned = value.replaceAll(',', '.');
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(cleaned)) {
      throw const FormatException('Invalid amount');
    }
    final parts = cleaned.split('.');
    final whole = parts[0].isEmpty ? BigInt.zero : BigInt.parse(parts[0]);
    final frac = parts.length > 1 ? parts[1] : '';
    final fracDigits = RegExp(r'^\d*$').hasMatch(frac) ? frac : '';
    final fracPadded = (fracDigits + '000000000').substring(0, 9);
    return whole * BigInt.from(1000000000) + BigInt.parse(fracPadded);
  }

  Future<void> _handleSendRequest() async {
    final result = await _promptAmountDialog(
      title: context.trNow('Send funds', 'Betrag senden'),
      description: context.trNow('Enter how much you want to send.', 'Gib den zu sendenden Betrag ein.'),
      includeAddress: true,
    );
    if (result == null) return;
    try {
      append('[S1] Creating slatepack...');
      final slate = await bridge.walletSendSlatepack(
        to: result.address?.trim() ?? '',
        amountNano: result.amountNano,
      );
      await _showSlateResultDialog(
        title: context.trNow('Share this slatepack with the receiver', 'Teile dieses Slatepack mit dem Empfaenger'),
        code: 'S1',
        slate: slate,
      );
      append('[S1] Slatepack ready. Share it with the receiver.');
    } catch (e) {
      append('[S1] Failed to create slatepack: $e');
    }
  }

  Future<void> _handleReceiveRequest() async {
    final result = await _promptAmountDialog(
      title: context.trNow('Request funds', 'Betrag anfragen'),
      description: context.trNow('Enter how much you expect to receive.', 'Gib den Betrag ein, den du erhalten moechtest.'),
      includeAddress: false,
    );
    if (result == null) return;
    try {
      append('[I1] Creating invoice slatepack...');
      final slate = await bridge.walletIssueInvoice(amountNano: result.amountNano);
      await _showSlateResultDialog(
        title: context.trNow('Share this invoice with the sender', 'Teile dieses Invoice-Slate mit dem Sender'),
        code: 'I1',
        slate: slate,
      );
      append('[I1] Invoice slatepack ready.');
    } catch (e) {
      append('[I1] Invoice creation failed: $e');
    }
  }

  Future<void> _handleIncomingSlate() async {
    final message = incomingSlateCtrl.text.trim();
    if (message.isEmpty) {
      append('Please paste a slatepack first.');
      return;
    }
    incomingSlateCtrl.clear();
    await _showIncomingActionDialog(message);
  }

  Future<void> _finalizeSlate(String code, String slate) async {
    final store = _walletStore;
    if (store == null) return;
    try {
      append('[$code] Finalizing and posting...');
      final finalized = await bridge.walletFinalizeSlatepack(
        message: slate,
        postTx: true,
        fluff: fluffTx,
      );
      append('[$code] Slate finalized (auto-post requested). Refreshing wallet data...');
      await Future.wait([
        store.refreshOverview(),
        store.refreshTransactions(refreshFromNode: true),
        store.refreshOutputs(refreshFromNode: true),
      ]);
      append('[$code] Finalize complete.');
    } catch (e) {
      final raw = e.toString();
      final friendly = raw.contains('DB Not Found Error')
          ? context.trNow(
              'Finalize failed: Slate not recognized. Use a response that belongs to this wallet.',
              'Finalisierung fehlgeschlagen: Slate unbekannt. Nutze eine Antwort, die zu diesem Wallet gehoert.',
            )
          : '[$code] Finalize failed: $raw';
      append(friendly);
    } finally {
      if (mounted) setState(() {});
    }
  }

  void _clearIncoming() {
    incomingSlateCtrl.clear();
    setState(() {});
  }

  Future<void> _pasteIntoIncoming() async {
    final data = await Clipboard.getData('text/plain');
    final value = data?.text?.trim();
    if (value == null || value.isEmpty) return;
    setState(() => incomingSlateCtrl.text = value);
    append('Slatepack pasted from clipboard.');
  }

  Future<_AmountDialogResult?> _promptAmountDialog({
    required String title,
    required String description,
    required bool includeAddress,
  }) async {
    final amountCtrl = TextEditingController(text: sendAmountCtrl.text);
    final addressCtrl = TextEditingController(text: sendAddressCtrl.text);
    return showDialog<_AmountDialogResult>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(description),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              decoration: InputDecoration(
                labelText: context.trNow('Amount (GRIN or nano)', 'Betrag (GRIN oder Nano)'),
              ),
            ),
            if (includeAddress) ...[
              const SizedBox(height: 12),
              TextField(
                controller: addressCtrl,
                decoration: InputDecoration(
                  labelText: context.trNow('Recipient slatepack address (optional)', 'Slatepack-Adresse (optional)'),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(context.trNow('Cancel', 'Abbrechen')),
          ),
          ElevatedButton(
            onPressed: () {
              try {
                final parsed = _parseAmount(amountCtrl.text);
                sendAmountCtrl.text = amountCtrl.text;
                if (includeAddress) {
                  sendAddressCtrl.text = addressCtrl.text;
                }
                Navigator.of(dialogCtx).pop(
                  _AmountDialogResult(
                    amountNano: parsed,
                    address: includeAddress ? addressCtrl.text : null,
                  ),
                );
              } catch (e) {
                append('Invalid amount: $e');
              }
            },
            child: Text(context.trNow('Confirm', 'Bestaetigen')),
          ),
        ],
      ),
    );
  }

  Future<void> _showSlateResultDialog({
    required String title,
    required String code,
    required String slate,
  }) async {
    final scrollCtrl = ScrollController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('$title ($code)'),
        content: SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: Scrollbar(
              controller: scrollCtrl,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: scrollCtrl,
                child: SelectableText(
                  slate,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: slate));
              append('$code copied to clipboard.');
            },
            child: Text(context.trNow('Copy', 'Kopieren')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(context.trNow('Close', 'Schliessen')),
          ),
        ],
      ),
    );
    scrollCtrl.dispose();
  }

  Future<void> _showTransactionSlatepack(TransactionModel tx) async {
    final scrollCtrl = ScrollController();
    final isIncoming = _isIncoming(tx);
    final amountAccent = isIncoming ? _receiveAccent : _sendAccent;
    try {
      final slate = await bridge.walletTransactionSlatepack(txId: tx.id);
      SlateInspection? inspection;
      try {
        final raw = await bridge.walletInspectSlatepack(message: slate);
        inspection = SlateInspection.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        append('Inspect failed for Tx ${tx.id}: $e');
      }
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: Text(context.trNow('Transaction slatepack', 'Transaktions-Slatepack')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (inspection != null) ...[
                  _buildSlateInfo(
                    inspection,
                    overrideAmount: tx.amount.abs(),
                    amountColor: amountAccent,
                  ),
                  const SizedBox(height: 12),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: Scrollbar(
                    controller: scrollCtrl,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: scrollCtrl,
                      child: SelectableText(
                        slate,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: slate));
                append('Tx ${tx.id} slate copied.');
              },
              child: Text(context.trNow('Copy', 'Kopieren')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(context.trNow('Close', 'Schliessen')),
            ),
          ],
        ),
      );
    } catch (e) {
      append('Failed to load slatepack for Tx ${tx.id}: $e');
    } finally {
      scrollCtrl.dispose();
    }
  }

  Future<void> _respondToIncomingSlate({
    required String slate,
    required bool isInvoice,
    required String code,
  }) async {
    try {
      append('[$code] Preparing response...');
      final nextSlate = isInvoice
          ? await bridge.walletProcessInvoice(message: slate)
          : await bridge.walletReceiveSlatepack(message: slate);
      final title = isInvoice
          ? context.trNow('Share this invoice response with the sender', 'Teile diese Invoice-Antwort mit dem Sender')
          : context.trNow('Share this response with the counterparty', 'Teile diese Antwort mit dem Gegenueber');
      await _showSlateResultDialog(
        title: title,
        code: code,
        slate: nextSlate,
      );
      append('[$code] Response created. Make sure to share it.');
    } catch (e) {
      append('[$code] Failed to create response: $e');
    }
  }

  Future<void> _showIncomingActionDialog(String slate) async {
    SlateInspection? inspection;
    try {
      final raw = await bridge.walletInspectSlatepack(message: slate);
      inspection = SlateInspection.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      append('Inspect failed: $e');
    }
    final normalizedCode = inspection?.code.toUpperCase() ?? '';
    final isInvoice = normalizedCode.startsWith('I') || _guessIsInvoice(slate);
    final canRespond = normalizedCode.startsWith('S1') || normalizedCode.startsWith('I1');
    final isFinalStage = normalizedCode.startsWith('S3') || normalizedCode.startsWith('I3');
    final isInitialStage = normalizedCode.startsWith('S1') || normalizedCode.startsWith('I1');
    final amountColor = isInvoice ? _sendAccent : _receiveAccent;
    BigInt? amountOverride;
    if ((inspection?.amount ?? 0) == 0) {
      amountOverride = _txAmountForSlate(inspection?.slateId);
    }
    final finalizeLabel = isInvoice
        ? context.trNow('Finalize as I3', 'Als I3 finalisieren')
        : context.trNow('Finalize as S3', 'Als S3 finalisieren');
    final responseLabel = isInvoice
        ? context.trNow('Create I2 response', 'I2-Antwort erzeugen')
        : context.trNow('Create S2 response', 'S2-Antwort erzeugen');
    final responseCode = isInvoice ? 'I2' : 'S2';

    final scrollCtrl = ScrollController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(context.trNow('Incoming slatepack', 'Eingehendes Slatepack')),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inspection != null) ...[
                _buildSlateInfo(
                  inspection,
                  overrideAmount: amountOverride,
                  amountColor: amountColor,
                ),
                const SizedBox(height: 12),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ScrollConfiguration(
                  behavior: const ScrollBehavior().copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    controller: scrollCtrl,
                    child: SelectableText(
                      slate,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: slate));
              append('Slatepack copied to clipboard.');
            },
            child: Text(context.trNow('Copy', 'Kopieren')),
          ),
          if (canRespond)
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogCtx).pop();
                await _respondToIncomingSlate(
                  slate: slate,
                  isInvoice: isInvoice,
                  code: responseCode,
                );
              },
              child: Text(responseLabel),
            ),
          if (!isFinalStage && !isInitialStage)
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogCtx).pop();
                final code = isInvoice ? 'I3' : 'S3';
                await _finalizeSlate(code, slate);
              },
              child: Text(finalizeLabel),
            ),
        ],
      ),
    );
    scrollCtrl.dispose();
  }

  bool _guessIsInvoice(String slate) {
    final lower = slate.toLowerCase();
    return lower.contains('invoice') || lower.contains('i2') || lower.contains('i1');
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<WalletStore>();
    if (!store.unlocked) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _buildToolbar(store),
              Expanded(child: _buildLockedBody()),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildToolbar(store),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 92,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: NavigationRail(
                      selectedIndex: panel.index,
                      onDestinationSelected: (idx) =>
                          setState(() => panel = WalletPanel.values[idx]),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        _railDest(context.tr('Overview', 'Uebersicht'), Icons.dashboard),
                        _railDest(context.tr('Transactions', 'Transaktionen'), Icons.swap_horiz),
                        _railDest(context.tr('Outputs', 'Outputs'), Icons.storage),
                        _railDest(context.tr('Slatepacks', 'Slatepacks'), Icons.all_inbox),
                        _railDest(context.tr('Swaps', 'Swaps'), Icons.link),
                        _railDest(context.tr('Accounts', 'Accounts'), Icons.account_tree),
                        _railDest(context.tr('TOR', 'TOR'), Icons.security),
                        _railDest(context.tr('API', 'API'), Icons.api),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: _buildPanel(store),
                          ),
                        ),
                        Container(
                          height: 200,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: _buildLogPanel(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLockedBody() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.tr('Unlock wallet', 'Wallet entsperren'),
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                const SizedBox(height: 16),
                TextField(
                  controller: dataDirCtrl,
                  decoration: InputDecoration(
                    labelText: context.tr('Wallet directory', 'Wallet-Verzeichnis'),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: context.tr(
                      'Wallet password (optional)',
                      'Wallet-Passwort (optional)',
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () => _unlock(create: false),
                        child: Text(context.tr('Unlock', 'Entsperren')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () async {
                          final password = await _promptPassword(
                            title: context.trNow(
                              'Set wallet password',
                              'Passwort fuer neue Wallet setzen',
                            ),
                            description: context.trNow(
                              'Leave empty to create an unprotected wallet.',
                              'Leer lassen, um keine Passphrase zu verwenden.',
                            ),
                          );
                          if (password == null) return;
                          await _unlock(create: true, overridePass: password);
                        },
                        child: Text(context.tr('Create & unlock', 'Erstellen & entsperren')),
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.vpn_key),
                    onPressed: _restoreWalletFromSeed,
                    label: Text(
                      context.tr('Restore from seed phrase', 'Aus Seed Phrase wiederherstellen'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    'You can open an existing wallet, create a new one, or restore from a seed phrase.',
                    'Du kannst eine bestehende Wallet oeffnen, eine neue erstellen oder aus einer Seed Phrase wiederherstellen.',
                  ),
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    'A passphrase is optional but recommended. Leave it empty if you prefer an unprotected wallet.',
                    'Eine Passphrase ist optional, aber empfohlen. Lass sie leer, wenn du keine Schutzphrase willst.',
                  ),
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    'After unlocking you can start a full sync via the toolbar button at any time.',
                    'Nach dem Entsperren kannst du ueber die Toolbar jederzeit einen vollen Sync starten.',
                  ),
                  style: const TextStyle(color: Colors.white70),
                ),
                if (log.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(context.tr('Latest message', 'Letzte Meldung'),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      log.split('\n').first,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  NavigationRailDestination _railDest(String label, IconData icon) =>
      NavigationRailDestination(
        icon: Icon(icon),
        selectedIcon: Icon(icon, color: Colors.deepPurpleAccent),
        label: Text(label),
      );

  Widget _buildPanel(WalletStore store) {
    switch (panel) {
      case WalletPanel.transactions:
        return _transactionsPanel(store);
      case WalletPanel.outputs:
        return _outputsPanel(store);
      case WalletPanel.slatepacks:
        return _slatepackPanel();
      case WalletPanel.swaps:
        return const SwapWizard();
      case WalletPanel.accounts:
        return _accountsPanel(store);
      case WalletPanel.tor:
        return _torPanel(store);
      case WalletPanel.api:
        return _apiPanel(store);
      case WalletPanel.overview:
      default:
        return _overviewPanel(store);
    }
  }

  Future<void> _checkForeignListener(String walletDir) async {
    final store = _walletStore;
    final secretPath = '$walletDir${Platform.pathSeparator}.foreign_api_secret';
    final secretFile = File(secretPath);
    if (!await secretFile.exists()) {
      append('Foreign secret missing at $secretPath');
      return;
    }
    try {
      final secret = (await secretFile.readAsString()).trim();
      if (secret.isEmpty) {
        append('Foreign secret is empty, cannot ping listener.');
        return;
      }
      final credentials = base64.encode(utf8.encode('grin:$secret'));
      final client = HttpClient();
      try {
        final request = await client.postUrl(Uri.parse('http://127.0.0.1:3415/v2/foreign'));
        request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
        request.add(utf8.encode(jsonEncode({
          'jsonrpc': '2.0',
          'method': 'check_version',
          'params': {},
          'id': 1,
        })));
        final response = await request.close().timeout(const Duration(seconds: 4));
        final body = await response.transform(utf8.decoder).join();
        final message =
            'Foreign listener ${response.statusCode}: ${body.isEmpty ? '<no data>' : body}';
        store?.updateForeignApiState(
          running: response.statusCode == 200,
          message: message,
        );
        append(message);
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      final message = 'Foreign listener ping failed: $e';
      store?.updateForeignApiState(running: false, message: message);
      append(message);
    }
  }

  Widget _torPanel(WalletStore store) {
    final status = store.torStatus;
    final running = status?.running ?? false;
    final onion = status?.onionAddress ?? '—';
    final slatepack = status?.slatepackAddress ?? store.walletAddress ?? '—';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overviewCard(
            title: 'TOR',
            subtitle: context.tr(
              'Start the built-in Tor hidden service to receive via Slatepack.',
              'Starte den integrierten Tor-Dienst, um per Slatepack zu empfangen.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Switch(
                      value: running,
                      onChanged: (v) async {
                        append(v ? 'Starting Tor…' : 'Stopping Tor…');
                        try {
                          await store.setTorRunning(v);
                          append(v ? 'Tor started.' : 'Tor stopped.');
                        } catch (e) {
                          append('Tor error: $e');
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: running ? Colors.green.withOpacity(0.15) : Colors.orange.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Text(
                        running
                            ? context.tr('Service is running', 'Dienst laeuft')
                            : context.tr('Service is stopped', 'Dienst gestoppt'),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: context.tr('Refresh', 'Aktualisieren'),
                      icon: const Icon(Icons.refresh),
                      onPressed: () async {
                        await store.refreshTorStatus();
                        append('Tor status refreshed.');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('Onion', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: SelectableText(onion, style: const TextStyle(fontFamily: 'monospace')),
                ),
                const SizedBox(height: 16),
                Text('Slatepack', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: SelectableText(slatepack, style: const TextStyle(fontFamily: 'monospace')),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

  Widget _apiPanel(WalletStore store) {
    final foreignMessage = store.foreignApiMessage ??
        context.tr('Foreign API status not known yet', 'Foreign-API Status noch nicht bekannt');
    final foreignRunning = store.foreignApiRunning;
    final owner = store.ownerApiStatus;
    final ownerRunning = owner?.running ?? false;
    final ownerAddr = owner?.listenAddr ?? '127.0.0.1:3420';
    final ownerStatusText = ownerRunning
        ? context.tr('Owner API running', 'Owner-API laeuft')
        : context.tr('Owner API stopped', 'Owner-API gestoppt');
    final ownerButtonLabel = ownerRunning
        ? context.tr('Restart Owner API', 'Owner-API neu starten')
        : context.tr('Start Owner API', 'Owner-API starten');
    final ownerStartingMessage =
        context.tr('Starting Owner API…', 'Owner-API wird gestartet…');
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overviewCard(
            title: context.tr('Foreign API', 'Foreign-API'),
            subtitle: context.tr(
              'Shows whether the local Foreign listener accepts calls.',
              'Zeigt, ob der lokale Foreign-Listener Anfragen entgegennimmt.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      foreignRunning ? Icons.check_circle : Icons.error_outline,
                      color: foreignRunning ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        foreignRunning
                            ? context.tr('Foreign API is responding', 'Foreign-API antwortet')
                            : context.tr('Foreign API unreachable', 'Foreign-API nicht erreichbar'),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    FilledButton(
                      onPressed: store.unlocked
                          ? () async {
                              final dir = Directory(dataDirCtrl.text.trim()).absolute.path;
                              await _checkForeignListener(dir);
                            }
                          : null,
                      child: Text(context.tr('Ping', 'Ping')),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(foreignMessage, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _overviewCard(
            title: context.tr('Owner API', 'Owner-API'),
            subtitle: context.tr(
              'Start the secure Owner interface for wallet management.',
              'Starte die sichere Owner-Schnittstelle fuer Wallet-Verwaltung.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      ownerRunning ? Icons.check_circle : Icons.power_settings_new,
                      color: ownerRunning ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(ownerStatusText, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    IconButton(
                  tooltip: context.tr('Refresh status', 'Status aktualisieren'),
                  icon: const Icon(Icons.refresh),
                  onPressed: store.unlocked ? () => store.refreshOwnerApiStatus() : null,
                ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: SelectableText(ownerAddr, style: const TextStyle(fontFamily: 'monospace')),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(ownerButtonLabel),
                  onPressed: store.ownerApiStarting || ownerRunning
                      ? null
                      : () async {
                          append(ownerStartingMessage);
                          await store.startOwnerApi();
                        },
                ),
                if (owner?.message != null) ...[
                  const SizedBox(height: 8),
                  Text(owner!.message!, style: const TextStyle(color: Colors.white70)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overviewPanel(WalletStore store) {
    final info = store.overview?.info;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _overviewCard(
            title: context.tr('Node connection', 'Node-Verbindung'),
            subtitle: context.tr(
              'Choose the node endpoint for syncing and sending transactions.',
              'Waehle den Node-Endpunkt fuer Syncs und Transaktionen.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nodeCtrl,
                  decoration: InputDecoration(
                    labelText: context.tr('Node URL', 'Node-URL'),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.03),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Colors.deepPurpleAccent),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: () => _setNode(nodeCtrl.text),
                      child: Text(context.tr('Apply', 'Uebernehmen')),
                    ),
                    ActionChip(
                      label: const Text('grincoin.org'),
                      onPressed: () => _setNode(_publicNode),
                    ),
                    ActionChip(
                      label: const Text('localhost'),
                      onPressed: () => _setNode(_localNode),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _overviewCard(
            title: context.tr('Wallet snapshot', 'Wallet-Uebersicht'),
            subtitle: context.tr(
              'Realtime balances and current chain height.',
              'Aktuelle Salden und Node-Infos.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _infoChip(context.tr('Node tip', 'Node-Tip'),
                        store.tipHeight?.toString() ?? '--'),
                    _infoChip(context.tr('Spendable', 'Verfuegbar'),
                        _formatBalance(info?.currentlySpendable)),
                    _infoChip(context.tr('Awaiting conf.', 'Ausstehend'),
                        _formatBalance(info?.awaitingConfirmation)),
                    _infoChip(context.tr('Locked', 'Gesperrt'),
                        _formatBalance(info?.locked)),
                    _infoChip(context.tr('Immature', 'Unreif'),
                        _formatBalance(info?.immature)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.schedule, size: 16, color: Colors.white54),
                    const SizedBox(width: 6),
                    Text(
                      context.tr(
                        'Last update: ${_formatUpdateTime(store.lastOverviewRefresh)}',
                        'Letzte Aktualisierung: ${_formatUpdateTime(store.lastOverviewRefresh)}',
                      ),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
          _overviewCard(
            title: context.tr('Slatepack address', 'Slatepack-Adresse'),
            subtitle: context.tr(
              'Share this address with trusted contacts.',
              'Teile diese Adresse mit vertrauenswuerdigen Kontakten.',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: SelectableText(
                    store.walletAddress ?? context.tr('Not available', 'Nicht verfuegbar'),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy),
                      label: Text(context.tr('Copy address', 'Adresse kopieren')),
                      onPressed: store.walletAddress == null
                          ? null
                          : () {
                              Clipboard.setData(
                                ClipboardData(text: store.walletAddress ?? ''),
                              );
                              append('Address copied.');
                            },
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.vpn_key),
                      label: Text(context.tr('Show seed phrase', 'Seed Phrase anzeigen')),
                      onPressed: store.unlocked ? _showSeedPhrase : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _transactionsPanel(WalletStore store) {
    final txs = List<TransactionModel>.from(store.transactions)
      ..sort((a, b) => b.creationTime.compareTo(a.creationTime));

    if (txs.isEmpty && store.loadingTransactions) {
      return const Center(child: CircularProgressIndicator());
    }
    if (txs.isEmpty) {
      return Center(child: Text(context.tr('No transactions yet.', 'Noch keine Transaktionen.')));
    }

    final listView = ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: txs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, idx) {
        final tx = txs[idx];
        final isIncoming = _isIncoming(tx);
        final accent = isIncoming ? _receiveAccent : _sendAccent;
        final amountPrefix = isIncoming ? '+' : '-';
        final confirmationLabel = tx.confirmationTime == null
            ? context.tr('Pending confirmation', 'Ausstehende Bestaetigung')
            : _formatTs(tx.confirmationTime!);
        final directionLabel = '${isIncoming ? context.tr('Deposit', 'Einzahlung') : context.tr('Withdrawal', 'Auszahlung')} (${tx.direction})';
        final canCancel = _canCancelTx(tx);
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: accent.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: accent.withOpacity(0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(isIncoming ? Icons.call_received : Icons.call_made, color: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Tx ${tx.id} - ${tx.status}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: context.tr('View slatepack', 'Slatepack anzeigen'),
                    onPressed: () => _showTransactionSlatepack(tx),
                    icon: const Icon(Icons.description_outlined),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      tx.txType,
                      style: const TextStyle(fontSize: 12, letterSpacing: 0.2),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '$amountPrefix${_formatBalance(tx.amount)}',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: accent,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 20,
                runSpacing: 10,
                children: [
                  _transactionDetail(
                    context.tr('Direction', 'Richtung'),
                    directionLabel,
                  ),
                  _transactionDetail(
                    context.tr('Created', 'Erstellt'),
                    _formatTs(tx.creationTime),
                  ),
                  _transactionDetail(
                    context.tr('Confirmed', 'Bestaetigt'),
                    confirmationLabel,
                  ),
                  _transactionDetail(
                    context.tr('Confirmations', 'Bestaetigungen'),
                    _confirmationProgressLabel(tx),
                  ),
                  if (tx.fee != null)
                    _transactionDetail(
                      context.tr('Fee', 'Gebuehr'),
                      _formatBalance(tx.fee),
                    ),
                  _transactionDetail(
                    context.tr('Inputs/Outputs', 'Inputs/Outputs'),
                    '${tx.inputs}/${tx.outputs}',
                  ),
                  if (tx.txSlateId != null)
                    _transactionDetail(
                      'Slate ID',
                      tx.txSlateId!,
                    ),
                ],
              ),
              if (canCancel)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.cancel_outlined),
                      label: Text(context.tr('Cancel transaction', 'Transaktion abbrechen')),
                      onPressed: () => _confirmCancelTx(store, tx),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );

    return Stack(
      children: [
        listView,
        if (store.loadingTransactions)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
  Widget _outputsPanel(WalletStore store) {
    if (store.loadingOutputs) {
      return const Center(child: CircularProgressIndicator());
    }
    if (store.outputs.isEmpty) {
      return Center(child: Text(context.tr('No outputs found.', 'Keine Outputs gefunden.')));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: store.outputs.length,
      itemBuilder: (_, idx) {
        final out = store.outputs[idx];
        return ListTile(
          title: Text(out.commitment),
          subtitle: Text('${out.status} | ${_formatBalance(out.value)}'),
        );
      },
    );
  }

  Widget _slatepackPanel() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          context.tr('Create request to send or receive funds', 'Erstelle eine Anfrage zum Senden oder Empfangen'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _sendAccent.withOpacity(0.35),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.upload),
                label: Text(context.tr('Send', 'Senden')),
                onPressed: _handleSendRequest,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _receiveAccent.withOpacity(0.35),
                  foregroundColor: Colors.black87,
                ),
                icon: const Icon(Icons.download),
                label: Text(context.tr('Receive', 'Empfangen')),
                onPressed: _handleReceiveRequest,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          context.tr('Enter received slatepack to create a response or finalize it', 'Eingehendes Slatepack einfuegen, um zu antworten oder zu finalisieren'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: incomingSlateCtrl,
          maxLines: 8,
          decoration: InputDecoration(
            labelText: context.tr('Incoming slatepack', 'Eingehendes Slatepack'),
            hintText: 'BEGINSLATEPACK...\n...\nENDSLATEPACK.',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.paste),
                label: Text(context.tr('Paste', 'Einfuegen')),
                onPressed: _pasteIntoIncoming,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.clear_all),
                label: Text(context.tr('Clear', 'Leeren')),
                onPressed: incomingSlateCtrl.text.isEmpty ? null : _clearIncoming,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          icon: const Icon(Icons.play_circle_fill),
          label: Text(context.tr('Process slatepack', 'Slatepack verarbeiten')),
          onPressed:
              incomingSlateCtrl.text.trim().isEmpty ? null : _handleIncomingSlate,
        ),
        ExpansionTile(
          title: Text(context.tr('Advanced options', 'Erweiterte Optionen')),
          children: [
            SwitchListTile.adaptive(
              value: fluffTx,
              title: Text(context.tr('Use Dandelion fluff', 'Dandelion Fluff verwenden')),
              subtitle: Text(
                context.tr(
                  'Only needed if your node requires fluff when posting.',
                  'Nur noetig, falls dein Node Fluff beim Posten erfordert.',
                ),
              ),
              onChanged: (value) => setState(() => fluffTx = value),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSlateInfo(
    SlateInspection inspection, {
    BigInt? overrideAmount,
    Color? amountColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _slateInfoRow(context.trNow('Detected type', 'Erkannter Typ'), inspection.code),
        _slateInfoRow(context.trNow('State', 'Status'), inspection.state),
        _slateInfoRow(
          context.trNow('Amount', 'Betrag'),
          _formatBalance(overrideAmount ?? BigInt.from(inspection.amount)),
          valueColor: amountColor,
        ),
        _slateInfoRow(
          context.trNow('Fee', 'Gebuehr'),
          _formatBalance(BigInt.from(inspection.fee)),
        ),
        _slateInfoRow(
          context.trNow('Participants', 'Teilnehmer'),
          inspection.numParticipants.toString(),
        ),
        if (inspection.kernelExcess != null)
          _slateInfoRow(context.trNow('Kernel', 'Kernel'), inspection.kernelExcess!),
      ],
    );
  }

  Widget _slateInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(WalletStore store) {
    final titleStyle = Theme.of(context)
        .textTheme
        .titleLarge
        ?.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Row(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.07),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.wallet, size: 20),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('Wallet control', 'Wallet-Steuerung'),
                    style: titleStyle,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    store.unlocked
                        ? context.tr('You are connected', 'Verbindung aktiv')
                        : context.tr('Please unlock to start', 'Bitte entsperre zum Starten'),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: context.tr('Toggle language', 'Sprache wechseln'),
                onPressed: () => context.read<LocaleStore>().toggle(),
                icon: const Icon(Icons.language),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.sync, size: 18),
                label: Text(context.tr('Refresh', 'Aktualisieren')),
                onPressed: store.unlocked
                    ? () async {
                        await store.refreshAll();
                        append('All data refreshed.');
                      }
                    : null,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.cloud_sync, size: 18),
                label: Text(context.tr('Full sync', 'Voller Sync')),
                onPressed:
                    store.unlocked && !_fullSyncInProgress ? _runFullSync : null,
              ),
              if (store.unlocked)
                OutlinedButton.icon(
                      icon: const Icon(Icons.logout),
                      label: Text(context.trNow('Logout', 'Abmelden')),
                  onPressed: _confirmLogout,
                ),
            ],
          ),
        ],
      ),
    );
  }



  Widget _accountsPanel(WalletStore store) {
    if (store.loadingAccounts) {
      return const Center(child: CircularProgressIndicator());
    }
    if (store.accounts.isEmpty) {
      return Center(child: Text(context.tr('No accounts yet.', 'Noch keine Accounts.')));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: store.accounts.length,
      itemBuilder: (_, idx) {
        final account = store.accounts[idx];
        return ListTile(
          title: Text(account.label),
          subtitle: Text(account.path),
          trailing: account.isActive
              ? const Icon(Icons.check_circle, color: Colors.green)
              : TextButton(
                  onPressed: () => store.setActiveAccount(account.label),
                  child: Text(context.tr('Activate', 'Aktivieren')),
                ),
        );
      },
    );
  }

  Widget _buildLogPanel() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxHeight: 180),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr('Log', 'Log'), style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ScrollConfiguration(
                  behavior: const ScrollBehavior().copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    controller: _logScrollCtrl,
                    child: SelectableText(
                      log,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _infoChip(String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0x332E1F74), Color(0x222E1F74)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
        ],
      ),
    );
  }

  String _formatBalance(BigInt? value) {
    if (value == null) return '--';
    final whole = value ~/ BigInt.from(1000000000);
    final fracRaw = (value.remainder(BigInt.from(1000000000))).toString().padLeft(9, '0');
    final frac = fracRaw.replaceFirst(RegExp(r'0+$'), '');
    return frac.isEmpty ? '$whole GRIN' : '$whole.$frac GRIN';
  }

  String _formatTs(DateTime dt) {
    final local = dt.toLocal();
    final date = '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '$date $time';
  }

  String _formatUpdateTime(DateTime? value) =>
      value == null ? context.tr('never', 'nie') : _formatTs(value);

  Widget _transactionDetail(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _overviewCard({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: Colors.white60)),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }

  String _confirmationProgressLabel(TransactionModel tx) {
    var value = tx.confirmations;
    if (!_canCancelTx(tx)) {
      value = value <= 0 ? 1 : value;
    }
    final clamped = value.clamp(0, 10);
    return '${clamped.toInt()}/10';
  }

  bool _isIncoming(TransactionModel tx) {
    bool containsAny(String input, List<String> patterns) {
      final lower = input.toLowerCase();
      return patterns.any((needle) => lower.contains(needle));
    }

    if (containsAny(tx.direction, const ['receive', 'incoming', 'deposit'])) return true;
    if (containsAny(tx.direction, const ['send', 'sent', 'withdraw', 'out'])) return false;
    if (containsAny(tx.txType, const ['receive', 'coinbase', 'deposit'])) return true;
    if (containsAny(tx.txType, const ['send', 'sent', 'withdraw', 'spend'])) return false;
    return !tx.amount.isNegative;
  }

  BigInt? _txAmountForSlate(String? slateId) {
    if (slateId == null || slateId.isEmpty) return null;
    final store = _walletStore;
    if (store == null) return null;
    try {
      final tx = store.transactions.firstWhere((tx) => tx.txSlateId == slateId);
      return tx.amount.abs();
    } catch (_) {
      return null;
    }
  }

  Future<void> _restoreWalletFromSeed() async {
    final dirRaw = dataDirCtrl.text.trim();
    if (dirRaw.isEmpty) {
      append('Directory required before restoring from seed.');
      return;
    }
    final dir = Directory(dirRaw).absolute.path;
    final phraseInput = await _promptSeedPhraseInput();
    if (phraseInput == null) return;
    final normalized = phraseInput
        .trim()
        .split(RegExp(r'\\s+'))
        .where((word) => word.isNotEmpty)
        .join(' ');
    if (normalized.isEmpty) {
      append('Seed phrase cannot be empty.');
      return;
    }
    final pass = await _promptPassword(
      title: context.trNow(
        'Set wallet password',
        'Wallet-Passwort festlegen',
      ),
      description: context.trNow(
        'Enter the password you want to use for this restored wallet (leave empty for none).',
        'Gib das Passwort fuer die wiederhergestellte Wallet ein (leer lassen fuer keines).',
      ),
    );
    if (pass == null) return;
    try {
      await _blockingTask(
        context.trNow('Restoring wallet...', 'Wallet wird wiederhergestellt...'),
        () async {
          await bridge.walletRestoreFromSeed(
            dataDir: dir,
            passphrase: pass,
            phrase: normalized,
          );
        },
      );
      _walletPass = pass;
      final store = _walletStore;
      if (store != null) {
        await store.onWalletUnlocked();
      }
      append('Wallet restored from seed phrase.');
    } catch (e) {
      append('Seed restore failed: $e');
    }
  }

  Future<String?> _promptSeedPhraseInput() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(context.tr('Enter seed phrase', 'Seed Phrase eingeben')),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            maxLines: 3,
            minLines: 2,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.tr('24-word seed', '24-Woerter-Seed'),
              hintText: context.tr(
                'word1 word2 ... word24',
                'wort1 wort2 ... wort24',
              ),
              helperText: context.tr(
                'Paste the full phrase as a single line separated by spaces.',
                'Fuege die gesamte Phrase als eine Zeile mit Leerzeichen ein.',
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(context.tr('Cancel', 'Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(controller.text),
            child: Text(context.tr('Restore', 'Wiederherstellen')),
          ),
        ],
      ),
    );
    return result;
  }

  Future<String?> _promptPassword({
    required String title,
    required String description,
    String? initialValue,
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.trNow('Password (optional)', 'Passwort (optional)'),
              helperText: description,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(context.trNow('Cancel', 'Abbrechen')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(context.trNow('Continue', 'Weiter')),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _showSeedPhrase() async {
    final dirRaw = dataDirCtrl.text.trim();
    if (dirRaw.isEmpty) {
      append('Cannot reveal seed phrase: wallet directory missing.');
      return;
    }
    final dir = Directory(dirRaw).absolute.path;
    var pass = _walletPass ?? passCtrl.text;
    pass = pass.trim().isEmpty
        ? (await _promptPassword(
            title: context.trNow('Enter wallet password', 'Wallet-Passwort eingeben'),
            description: context.trNow(
              'We need the wallet password to show the seed phrase.',
              'Zum Anzeigen der Seed Phrase wird das Wallet-Passwort benoetigt.',
            ),
            initialValue: passCtrl.text,
          )) ??
            ''
        : pass;
    String? phrase;
    try {
      await _blockingTask(
        context.trNow('Retrieving seed phrase...', 'Seed Phrase wird geladen...'),
        () async {
          phrase = await bridge.walletSeedPhrase(dataDir: dir, passphrase: pass);
        },
      );
    } catch (e) {
      append('Seed phrase retrieval failed: $e');
      return;
    }
    if (!mounted || phrase == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(context.tr('Seed phrase', 'Seed Phrase')),
        content: SelectableText(
          phrase!,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: phrase!));
              append('Seed phrase copied to clipboard.');
              Navigator.of(dialogCtx).pop();
            },
            child: Text(context.tr('Copy', 'Kopieren')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(context.tr('Close', 'Schliessen')),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(context.tr('Logout wallet?', 'Wallet abmelden?')),
        content: Text(
          context.tr(
            'This will lock the wallet and stop auto-refresh. Continue?',
            'Dadurch wird die Wallet gesperrt und Auto-Refresh gestoppt. Fortfahren?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: Text(context.tr('Cancel', 'Abbrechen')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: Text(context.tr('Logout', 'Abmelden')),
          ),
        ],
      ),
    );
    if (shouldLogout != true) return;
    final store = _walletStore;
    if (store != null) {
      store.unlocked = false;
      store.notifyListeners();
    }
    setState(() {
      _walletPass = null;
    });
    append('Wallet locked.');
  }
}

class _BlockingDialog extends StatelessWidget {
  const _BlockingDialog({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class _AmountDialogResult {
  const _AmountDialogResult({required this.amountNano, this.address});

  final BigInt amountNano;
  final String? address;
}

class SlateInspection {
  SlateInspection({
    required this.code,
    required this.slateId,
    required this.state,
    required this.amount,
    required this.fee,
    required this.numParticipants,
    this.kernelExcess,
  });

  factory SlateInspection.fromJson(Map<String, dynamic> json) => SlateInspection(
        code: json['code'] as String? ?? 'unknown',
        slateId: json['slateId'] as String? ?? '',
        state: json['state'] as String? ?? 'unknown',
        amount: _parseInt(json['amount']),
        fee: _parseInt(json['fee']),
        numParticipants: _parseInt(json['numParticipants']),
        kernelExcess: json['kernelExcess'] as String?,
      );

  final String code;
  final String slateId;
  final String state;
  final int amount;
  final int fee;
  final int numParticipants;
  final String? kernelExcess;

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String && value.isNotEmpty) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }
}

