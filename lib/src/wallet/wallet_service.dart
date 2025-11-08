import 'dart:convert';

import '../rust/frb_generated.dart/api.dart' as bridge;
import 'models.dart';

class WalletService {
  Future<void> setNodeUrl(String url) => bridge.setNodeUrl(url: url.trim());

  Future<String> getNodeUrl() => bridge.getNodeUrl();

  Future<BigInt> getNodeTip() => bridge.getNodeTip();

  Future<String> fetchAddress() => bridge.walletGetAddress();

  Future<WalletInfoModel> fetchWalletInfo() async {
    final raw = await bridge.walletInfo();
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return WalletInfoModel.fromJson(data);
  }

  Future<List<TransactionModel>> fetchTransactions({
    required bool refreshFromNode,
  }) async {
    final raw = await bridge.walletListTransactions(refreshFromNode: refreshFromNode);
    return _parseList(raw, TransactionModel.fromJson);
  }

  Future<List<OutputModel>> fetchOutputs({
    required bool includeSpent,
    required bool refreshFromNode,
  }) async {
    final raw = await bridge.walletListOutputs(
      includeSpent: includeSpent,
      refreshFromNode: refreshFromNode,
    );
    return _parseList(raw, OutputModel.fromJson);
  }

  Future<void> cancelTx(int txId) => bridge.walletCancelTx(txId: txId);

  Future<void> repostTx(int txId, {required bool fluff}) =>
      bridge.walletRepostTx(txId: txId, fluff: fluff);

  Future<ScanResultModel> scan({
    required bool deleteUnconfirmed,
    int? startHeight,
    int? backwardsFromTip,
  }) async {
    final raw = await bridge.walletScan(
      deleteUnconfirmed: deleteUnconfirmed,
      startHeight: startHeight == null ? null : BigInt.from(startHeight),
      backwardsFromTip: backwardsFromTip == null ? null : BigInt.from(backwardsFromTip),
    );
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return ScanResultModel.fromJson(data);
  }

  Future<List<AccountModel>> fetchAccounts() async {
    final raw = await bridge.walletListAccounts();
    return _parseList(raw, AccountModel.fromJson);
  }

  Future<AccountModel> createAccount(String label) async {
    final raw = await bridge.walletCreateAccount(label: label);
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return AccountModel.fromJson(data);
  }

  Future<AccountModel> setActiveAccount(String label) async {
    final raw = await bridge.walletSetActiveAccount(label: label);
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return AccountModel.fromJson(data);
  }

  Future<String> activeAccount() => bridge.walletActiveAccount();

  Future<PaymentProofModel> fetchPaymentProof(int txId) async {
    final raw = await bridge.walletPaymentProof(txId: txId);
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return PaymentProofModel.fromJson(data, raw: raw);
  }

  Future<PaymentProofVerification> verifyPaymentProof(String payload) async {
    final raw = await bridge.walletVerifyPaymentProof(payload: payload);
    final Map<String, dynamic> data = jsonDecode(raw) as Map<String, dynamic>;
    return PaymentProofVerification.fromJson(data);
  }

  List<T> _parseList<T>(
    String raw,
    T Function(Map<String, dynamic> json) mapper,
  ) {
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((item) => mapper(Map<String, dynamic>.from(item as Map)))
        .toList();
  }
}
