import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'wallet_service.dart';

class WalletStore extends ChangeNotifier {
  WalletStore(this._service);

  final WalletService _service;

  WalletInfoModel? overview;
  List<TransactionModel> transactions = const [];
  List<OutputModel> outputs = const [];
  List<AccountModel> accounts = const [];
  PaymentProofModel? latestProof;
  PaymentProofVerification? proofVerification;
  ScanResultModel? lastScan;
  String? nodeUrl;
  String? walletAddress;
  BigInt? tipHeight;
  String? lastError;
  TorStatusModel? torStatus;
  bool foreignApiRunning = false;
  String? foreignApiMessage;
  OwnerListenerStatusModel? ownerApiStatus;
  bool ownerApiStarting = false;
  bool includeSpentOutputs = false;
  bool loadingOverview = false;
  bool loadingTransactions = false;
  bool loadingOutputs = false;
  bool loadingAccounts = false;
  bool loadingProof = false;
  bool loadingScan = false;
  bool unlocked = false;
  Timer? _autoRefresh;
  DateTime? lastOverviewRefresh;
  DateTime? lastTransactionsRefresh;
  DateTime? lastOutputsRefresh;
  List<AtomicSwapModel> atomicSwaps = const [];
  AtomicSwapModel? latestAtomicSwap;
  bool loadingAtomicSwaps = false;
  bool atomicSwapBusy = false;
  String? atomicSwapMessage;
  String? atomicSwapChecksum;
  String atomicSwapDirectory = 'wallet_data/atomic_swap_txs';
  String atomicSwapHost = '127.0.0.1';
  String atomicSwapPort = '80';

  Future<void> bootstrap({required String defaultNode}) async {
    await _ensureNode(defaultNode);
  }

  Future<void> onWalletUnlocked() async {
    unlocked = true;
    await refreshAll();
    _startAutoRefresh();
    notifyListeners();
  }

  Future<void> refreshAll() async {
    if (!unlocked) return;
    await Future.wait([
      refreshOverview(),
      refreshTransactions(refreshFromNode: true),
      refreshOutputs(refreshFromNode: true),
      refreshAccounts(),
      refreshTorStatus(),
      refreshOwnerApiStatus(),
    ]);
  }

  Future<void> updateNode(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    await _service.setNodeUrl(trimmed);
    nodeUrl = trimmed;
    notifyListeners();
    await refreshOverview();
  }

  Future<void> refreshOverview() async {
    if (!unlocked || loadingOverview) return;
    loadingOverview = true;
    notifyListeners();
    try {
      overview = await _service.fetchWalletInfo();
      tipHeight = await _service.getNodeTip();
      walletAddress = await _service.fetchAddress();
      nodeUrl ??= await _service.getNodeUrl();
      // also keep tor slatepack in sync if provided
      try {
        torStatus ??= await _service.torStatus();
      } catch (_) {}
      lastError = null;
      lastOverviewRefresh = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingOverview = false;
      notifyListeners();
    }
  }

  Future<void> refreshTransactions({bool refreshFromNode = false}) async {
    if (!unlocked || loadingTransactions) return;
    loadingTransactions = true;
    notifyListeners();
    try {
      transactions =
          await _service.fetchTransactions(refreshFromNode: refreshFromNode);
      lastError = null;
      lastTransactionsRefresh = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingTransactions = false;
      notifyListeners();
    }
  }

  Future<void> refreshTorStatus() async {
    if (!unlocked) return;
    try {
      torStatus = await _service.torStatus();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> refreshOwnerApiStatus() async {
    if (!unlocked) return;
    try {
      ownerApiStatus = await _service.fetchOwnerListenerStatus();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> startOwnerApi() async {
    if (!unlocked || ownerApiStarting) return;
    ownerApiStarting = true;
    notifyListeners();
    try {
      ownerApiStatus = await _service.startOwnerListener();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      ownerApiStarting = false;
      notifyListeners();
    }
  }

  void updateForeignApiState({required bool running, required String message}) {
    foreignApiRunning = running;
    foreignApiMessage = message;
    notifyListeners();
  }

  Future<void> setTorRunning(bool value) async {
    if (!unlocked) return;
    if (value) {
      torStatus = await _service.torStart();
    } else {
      await _service.torStop();
      torStatus = TorStatusModel(running: false, onionAddress: torStatus?.onionAddress, slatepackAddress: walletAddress);
    }
    notifyListeners();
  }

  Future<void> refreshOutputs({bool refreshFromNode = false}) async {
    if (!unlocked || loadingOutputs) return;
    loadingOutputs = true;
    notifyListeners();
    try {
      outputs = await _service.fetchOutputs(
        includeSpent: includeSpentOutputs,
        refreshFromNode: refreshFromNode,
      );
      lastError = null;
      lastOutputsRefresh = DateTime.now();
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingOutputs = false;
      notifyListeners();
    }
  }

  Future<void> refreshAccounts() async {
    if (!unlocked || loadingAccounts) return;
    loadingAccounts = true;
    notifyListeners();
    try {
      accounts = await _service.fetchAccounts();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingAccounts = false;
      notifyListeners();
    }
  }

  Future<void> createAccount(String label) async {
    if (label.trim().isEmpty) return;
    await _service.createAccount(label);
    await refreshAccounts();
  }

  Future<void> setActiveAccount(String label) async {
    if (label.trim().isEmpty) return;
    await _service.setActiveAccount(label);
    await refreshAccounts();
    await refreshOverview();
  }

  Future<void> cancelTx(int txId) async {
    await _service.cancelTx(txId);
    await refreshTransactions(refreshFromNode: true);
    await refreshOverview();
  }

  Future<void> repostTx(int txId, {required bool fluff}) async {
    await _service.repostTx(txId, fluff: fluff);
    await refreshTransactions(refreshFromNode: true);
  }

  Future<void> runScan({
    required bool deleteUnconfirmed,
    int? startHeight,
    int? backwardsFromTip,
  }) async {
    loadingScan = true;
    notifyListeners();
    try {
      lastScan = await _service.scan(
        deleteUnconfirmed: deleteUnconfirmed,
        startHeight: startHeight,
        backwardsFromTip: backwardsFromTip,
      );
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingScan = false;
      notifyListeners();
    }
  }

  Future<void> fetchPaymentProof(int txId) async {
    loadingProof = true;
    notifyListeners();
    try {
      latestProof = await _service.fetchPaymentProof(txId);
      proofVerification = null;
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingProof = false;
      notifyListeners();
    }
  }

  Future<void> verifyPaymentProof(String payload) async {
    if (payload.trim().isEmpty) return;
    loadingProof = true;
    notifyListeners();
    try {
      proofVerification = await _service.verifyPaymentProof(payload);
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      loadingProof = false;
      notifyListeners();
    }
  }

  Future<void> toggleIncludeSpentOutputs(bool value) async {
    includeSpentOutputs = value;
    notifyListeners();
    if (!unlocked) return;
    await refreshOutputs(refreshFromNode: true);
  }

  Future<void> refreshAtomicSwaps() async {
    if (!unlocked || loadingAtomicSwaps) return;
    loadingAtomicSwaps = true;
    notifyListeners();
    try {
      atomicSwaps = await _service.listAtomicSwaps();
      atomicSwapMessage = null;
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      loadingAtomicSwaps = false;
      notifyListeners();
    }
  }

  Future<void> createAtomicSwap({
    required String fromCurrency,
    required String toCurrency,
    required BigInt fromAmount,
    required BigInt toAmount,
    required BigInt timeoutMinutes,
  }) async {
    if (!unlocked || atomicSwapBusy) return;
    atomicSwapBusy = true;
    notifyListeners();
    try {
      latestAtomicSwap = await _service.createAtomicSwap(
        fromCurrency: fromCurrency,
        toCurrency: toCurrency,
        fromAmount: fromAmount,
        toAmount: toAmount,
        timeoutMinutes: timeoutMinutes,
      );
      atomicSwapMessage = null;
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      atomicSwapBusy = false;
      notifyListeners();
    }
  }

  Future<void> acceptAtomicSwap(int swapId) async {
    if (!unlocked || atomicSwapBusy) return;
    atomicSwapBusy = true;
    notifyListeners();
    try {
      latestAtomicSwap = await _service.acceptAtomicSwap(swapId);
      atomicSwapMessage = null;
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      atomicSwapBusy = false;
      notifyListeners();
    }
  }

  Future<void> inspectAtomicSwap(int swapId) async {
    if (!unlocked) return;
    try {
      latestAtomicSwap = await _service.inspectAtomicSwap(swapId);
      atomicSwapMessage = null;
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<String> fetchAtomicSwapPayload(int swapId) async {
    // Always fetch the raw record so the payload contains the swap id and pub_slate.
    return _service.atomicSwapRaw(swapId);
  }

  Future<void> importAtomicSwap(int swapId, String payload) async {
    if (!unlocked || atomicSwapBusy) return;
    atomicSwapBusy = true;
    notifyListeners();
    try {
      await _service.atomicSwapImport(swapId, payload);
      atomicSwapMessage = null;
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      atomicSwapBusy = false;
      notifyListeners();
    }
  }

  Future<void> setAtomicSwapDirectory(String path) async {
    try {
      await _service.setAtomicSwapDirectory(path);
      atomicSwapDirectory = path;
      atomicSwapMessage = 'Using swap directory $path';
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> setAtomicSwapPeer(String host, String port) async {
    try {
      await _service.atomicSwapSetPeer(host, port);
      atomicSwapHost = host;
      atomicSwapPort = port;
      atomicSwapMessage = 'Using peer $host:$port';
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> refreshAtomicSwapChecksum(int swapId) async {
    if (!unlocked) return;
    try {
      atomicSwapChecksum = await _service.atomicSwapChecksum(swapId);
      atomicSwapMessage = null;
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> lockAtomicSwap(int swapId) async {
    if (!unlocked || atomicSwapBusy) return;
    atomicSwapBusy = true;
    notifyListeners();
    try {
      await _service.atomicSwapLock(swapId);
      atomicSwapMessage = 'Swap $swapId locked.';
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      atomicSwapBusy = false;
      notifyListeners();
    }
  }

  Future<void> executeAtomicSwap(int swapId) async {
    if (!unlocked || atomicSwapBusy) return;
    atomicSwapBusy = true;
    notifyListeners();
    try {
      await _service.atomicSwapExecute(swapId);
      atomicSwapMessage = 'Swap $swapId executed.';
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      atomicSwapBusy = false;
      notifyListeners();
    }
  }

  Future<void> cancelAtomicSwap(int swapId) async {
    if (!unlocked || atomicSwapBusy) return;
    atomicSwapBusy = true;
    notifyListeners();
    try {
      await _service.atomicSwapCancel(swapId);
      atomicSwapMessage = 'Swap $swapId cancelled.';
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      atomicSwapBusy = false;
      notifyListeners();
    }
  }

  Future<void> deleteAtomicSwap(int swapId) async {
    if (!unlocked) return;
    try {
      final msg = await _service.atomicSwapDelete(swapId);
      atomicSwapMessage = msg;
      await refreshAtomicSwaps();
    } catch (e) {
      atomicSwapMessage = e.toString();
    } finally {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
  }

  AtomicSwapModel? _findAtomicSwapById(int swapId) {
    for (final swap in atomicSwaps) {
      if (swap.id == swapId) return swap;
    }
    if (latestAtomicSwap?.id == swapId) {
      return latestAtomicSwap;
    }
    return null;
  }

  Future<void> _ensureNode(String fallback) async {
    try {
      nodeUrl = await _service.getNodeUrl();
      if (nodeUrl == null || nodeUrl!.isEmpty) {
        await updateNode(fallback);
      }
    } catch (_) {
      await updateNode(fallback);
    }
  }

  void _startAutoRefresh() {
    if (!unlocked) return;
    _autoRefresh?.cancel();
    _autoRefresh = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!loadingOverview) {
        unawaited(refreshOverview());
      }
      if (overview != null && !loadingTransactions) {
        unawaited(refreshTransactions());
      }
    });
  }
}
