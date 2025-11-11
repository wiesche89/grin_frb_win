// lib/test_support/fakes.dart
import 'dart:convert';

import 'package:grin_frb_win/src/wallet/wallet_service.dart';
import 'package:grin_frb_win/src/wallet/wallet_store.dart';
import 'package:grin_frb_win/src/wallet/models.dart';

/// Vollständiger Fake für WalletService: keine FRB-Aufrufe, nur Stub-Daten.
class FakeWalletService extends WalletService {
  String _nodeUrl = 'https://grin.mw';
  bool _torRunning = false;
  bool _ownerRunning = false;
  String _activeAccount = 'default';

  @override
  Future<void> setNodeUrl(String url) async {
    _nodeUrl = url.trim();
  }

  @override
  Future<String> getNodeUrl() async => _nodeUrl;

  @override
  Future<BigInt> getNodeTip() async => BigInt.from(123456);

  @override
  Future<String> fetchAddress() async =>
      'grin1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';

  @override
  Future<WalletInfoModel> fetchWalletInfo() async {
    // Minimales, valides WalletInfoModel
    return WalletInfoModel(
      refreshedFromNode: true,
      info: WalletInfoDetails(
        lastConfirmedHeight: 123450,
        minimumConfirmations: 10,
        total: BigInt.from(1000000000),
        awaitingFinalization: BigInt.zero,
        awaitingConfirmation: BigInt.zero,
        immature: BigInt.zero,
        currentlySpendable: BigInt.from(999000000),
        locked: BigInt.from(1000000),
        reverted: BigInt.zero,
      ),
      activeAccount: _activeAccount,
    );
  }

  @override
  Future<List<TransactionModel>> fetchTransactions({
    required bool refreshFromNode,
  }) async {
    final tx = TransactionModel.fromJson({
      'id': 1,
      'txSlateId': null,
      'txType': 'received',
      'status': 'confirmed',
      'direction': 'received',
      'creationTs': DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
      'confirmationTs': DateTime.now().toIso8601String(),
      'confirmed': true,
      'amount': '100000000',
      'fee': null,
      'numInputs': 0,
      'numOutputs': 1,
      'hasProof': false,
      'kernelExcess': null,
      'ttlCutoffHeight': null,
      'revertedAfterSecs': null,
      'confirmations': 12,
    });
    return [tx];
  }

  @override
  Future<List<OutputModel>> fetchOutputs({
    required bool includeSpent,
    required bool refreshFromNode,
  }) async {
    final out = OutputModel.fromJson({
      'commitment': '08abc...',
      'value': '100000000',
      'status': 'unspent',
      'height': 123400,
      'lockHeight': 0,
      'isCoinbase': false,
      'mmrIndex': 1,
      'txLogId': 1,
      'confirmations': 50,
      'spendable': true,
    });
    return [out];
  }

  @override
  Future<void> cancelTx(int txId) async {
    // no-op
  }

  @override
  Future<void> repostTx(int txId, {required bool fluff}) async {
    // no-op
  }

  @override
  Future<ScanResultModel> scan({
    required bool deleteUnconfirmed,
    int? startHeight,
    int? backwardsFromTip,
  }) async {
    return ScanResultModel(
      deleteUnconfirmed: deleteUnconfirmed,
      startHeight: startHeight,
      backwardsFromTip: backwardsFromTip,
      performedAtEpochSecs: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  @override
  Future<List<AccountModel>> fetchAccounts() async {
    return <AccountModel>[
      AccountModel.fromJson({
        'label': 'default',
        'path': 'm/0',
        'isActive': _activeAccount == 'default',
      }),
      AccountModel.fromJson({
        'label': 'savings',
        'path': 'm/1',
        'isActive': _activeAccount == 'savings',
      }),
    ];
  }

  @override
  Future<AccountModel> createAccount(String label) async {
    _activeAccount = label;
    return AccountModel.fromJson({
      'label': _activeAccount,
      'path': 'm/9',
      'isActive': true,
    });
  }

  @override
  Future<AccountModel> setActiveAccount(String label) async {
    _activeAccount = label;
    return AccountModel.fromJson({
      'label': _activeAccount,
      'path': 'm/0',
      'isActive': true,
    });
  }

  @override
  Future<String> activeAccount() async => _activeAccount;

  @override
  Future<PaymentProofModel> fetchPaymentProof(int txId) async {
    final proofMap = {
      'txId': txId,
      'proof': {
        'receiver': 'grin1qq...',
        'amount': '100000000',
        'height': 123456,
      },
    };
    final raw = jsonEncode(proofMap);
    return PaymentProofModel.fromJson(
      Map<String, dynamic>.from(proofMap),
      raw: raw,
    );
  }

  @override
  Future<PaymentProofVerification> verifyPaymentProof(String payload) async {
    // Dein models.dart verlangt nur isSender/isRecipient.
    return PaymentProofVerification(
      isSender: true,
      isRecipient: true,
    );
  }

  // --- Tor service ---

  @override
  Future<TorStatusModel> torStatus() async {
    return TorStatusModel(
      running: _torRunning,
      onionAddress: _torRunning ? 'abc123.onion' : null,
      slatepackAddress: _torRunning ? 'grin1slatepack...' : null,
    );
    }

  @override
  Future<TorStatusModel> torStart({String listenAddr = '127.0.0.1:3415'}) async {
    _torRunning = true;
    return TorStatusModel(
      running: true,
      onionAddress: 'abc123.onion',
      slatepackAddress: 'grin1slatepack...',
    );
  }

  @override
  Future<void> torStop() async {
    _torRunning = false;
  }

  @override
  Future<OwnerListenerStatusModel> fetchOwnerListenerStatus() async {
    return OwnerListenerStatusModel(
      running: _ownerRunning,
      listenAddr: '127.0.0.1:3420',
    );
  }

  @override
  Future<OwnerListenerStatusModel> startOwnerListener() async {
    _ownerRunning = true;
    return OwnerListenerStatusModel(
      running: true,
      listenAddr: '127.0.0.1:3420',
    );
  }
}

/// Fake-Store vermeidet Service-/FRB-Aufrufe beim Bootstrap.
class FakeWalletStore extends WalletStore {
  FakeWalletStore() : super(FakeWalletService());

  @override
  Future<void> bootstrap({required String defaultNode}) async {
    nodeUrl = defaultNode; // kein _ensureNode(), keine FRB-Calls
    notifyListeners();
  }

  @override
  Future<void> updateNode(String url) async {
    nodeUrl = url.trim();
    notifyListeners();
  }
}
