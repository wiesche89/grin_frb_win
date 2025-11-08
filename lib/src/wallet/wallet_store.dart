import 'dart:async';

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

  @override
  void dispose() {
    _autoRefresh?.cancel();
    super.dispose();
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
