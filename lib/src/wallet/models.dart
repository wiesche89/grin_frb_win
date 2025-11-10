import 'dart:convert';

BigInt _bigInt(dynamic value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is num) return BigInt.from(value.toInt());
  if (value is String) return BigInt.parse(value);
  throw ArgumentError('Unsupported numeric value: $value');
}

int _int(dynamic value) {
  final result = _intOrNull(value);
  if (result == null) {
    throw ArgumentError('Expected int-compatible value but got $value');
  }
  return result;
}

int? _intOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String && value.isNotEmpty) return int.parse(value);
  return null;
}

class WalletInfoModel {
  WalletInfoModel({
    required this.refreshedFromNode,
    required this.info,
    required this.activeAccount,
  });

  factory WalletInfoModel.fromJson(Map<String, dynamic> json) => WalletInfoModel(
        refreshedFromNode: json['refreshedFromNode'] as bool? ?? false,
        info: WalletInfoDetails.fromJson(
          Map<String, dynamic>.from(json['info'] as Map),
        ),
        activeAccount: json['activeAccount'] as String? ?? 'default',
      );

  final bool refreshedFromNode;
  final WalletInfoDetails info;
  final String activeAccount;
}

class WalletInfoDetails {
  WalletInfoDetails({
    required this.lastConfirmedHeight,
    required this.minimumConfirmations,
    required this.total,
    required this.awaitingFinalization,
    required this.awaitingConfirmation,
    required this.immature,
    required this.currentlySpendable,
    required this.locked,
    required this.reverted,
  });

  factory WalletInfoDetails.fromJson(Map<String, dynamic> json) => WalletInfoDetails(
        lastConfirmedHeight: _int(json['last_confirmed_height']),
        minimumConfirmations: _int(json['minimum_confirmations']),
        total: _bigInt(json['total']),
        awaitingFinalization: _bigInt(json['amount_awaiting_finalization']),
        awaitingConfirmation: _bigInt(json['amount_awaiting_confirmation']),
        immature: _bigInt(json['amount_immature']),
        currentlySpendable: _bigInt(json['amount_currently_spendable']),
        locked: _bigInt(json['amount_locked']),
        reverted: _bigInt(json['amount_reverted']),
      );

  final int lastConfirmedHeight;
  final int minimumConfirmations;
  final BigInt total;
  final BigInt awaitingFinalization;
  final BigInt awaitingConfirmation;
  final BigInt immature;
  final BigInt currentlySpendable;
  final BigInt locked;
  final BigInt reverted;
}

class TransactionModel {
  TransactionModel({
    required this.id,
    this.txSlateId,
    required this.txType,
    required this.status,
    required this.direction,
    required this.creationTime,
    this.confirmationTime,
    required this.confirmed,
    required this.amount,
    this.fee,
    required this.inputs,
    required this.outputs,
    required this.hasProof,
    this.kernelExcess,
    this.ttlCutoffHeight,
    this.revertedAfterSecs,
    required this.confirmations,
  });

  factory TransactionModel.fromJson(Map<String, dynamic> json) => TransactionModel(
        id: json['id'] as int,
        txSlateId: json['txSlateId'] as String?,
        txType: json['txType'] as String? ?? 'unknown',
        status: json['status'] as String? ?? 'pending',
        direction: json['direction'] as String? ?? 'received',
        creationTime: DateTime.parse(json['creationTs'] as String),
        confirmationTime: (json['confirmationTs'] as String?)?.let(DateTime.parse),
        confirmed: json['confirmed'] as bool? ?? false,
        amount: _bigInt(json['amount']),
        fee: json['fee'] == null ? null : _bigInt(json['fee']),
        inputs: _intOrNull(json['numInputs']) ?? 0,
        outputs: _intOrNull(json['numOutputs']) ?? 0,
        hasProof: json['hasProof'] as bool? ?? false,
        kernelExcess: json['kernelExcess'] as String?,
        ttlCutoffHeight: _intOrNull(json['ttlCutoffHeight']),
        revertedAfterSecs: _intOrNull(json['revertedAfterSecs']),
        confirmations: _intOrNull(json['confirmations']) ?? 0,
      );

  final int id;
  final String? txSlateId;
  final String txType;
  final String status;
  final String direction;
  final DateTime creationTime;
  final DateTime? confirmationTime;
  final bool confirmed;
  final BigInt amount;
  final BigInt? fee;
  final int inputs;
  final int outputs;
  final bool hasProof;
  final String? kernelExcess;
  final int? ttlCutoffHeight;
  final int? revertedAfterSecs;
  final int confirmations;
}

extension<T> on T {
  R let<R>(R Function(T value) block) => block(this);
}

class OutputModel {
  OutputModel({
    required this.commitment,
    required this.value,
    required this.status,
    required this.height,
    required this.lockHeight,
    required this.isCoinbase,
    this.mmrIndex,
    this.txLogId,
    required this.confirmations,
    required this.spendable,
  });

  factory OutputModel.fromJson(Map<String, dynamic> json) => OutputModel(
        commitment: json['commitment'] as String? ?? '',
        value: _bigInt(json['value']),
        status: json['status'] as String? ?? 'unspent',
        height: _int(json['height']),
        lockHeight: _int(json['lockHeight']),
        isCoinbase: json['isCoinbase'] as bool? ?? false,
        mmrIndex: _intOrNull(json['mmrIndex']),
        txLogId: _intOrNull(json['txLogId']),
        confirmations: _int(json['confirmations']),
        spendable: json['spendable'] as bool? ?? false,
      );

  final String commitment;
  final BigInt value;
  final String status;
  final int height;
  final int lockHeight;
  final bool isCoinbase;
  final int? mmrIndex;
  final int? txLogId;
  final int confirmations;
  final bool spendable;
}

class AccountModel {
  AccountModel({
    required this.label,
    required this.path,
    required this.isActive,
  });

  factory AccountModel.fromJson(Map<String, dynamic> json) => AccountModel(
        label: json['label'] as String? ?? 'default',
        path: json['path'] as String? ?? 'm/0/0',
        isActive: json['isActive'] as bool? ?? false,
      );

  final String label;
  final String path;
  final bool isActive;
}

class ScanResultModel {
  ScanResultModel({
    required this.deleteUnconfirmed,
    this.startHeight,
    this.backwardsFromTip,
    required this.performedAtEpochSecs,
  });

  factory ScanResultModel.fromJson(Map<String, dynamic> json) => ScanResultModel(
        deleteUnconfirmed: json['deleteUnconfirmed'] as bool? ?? false,
        startHeight: _intOrNull(json['startHeight']),
        backwardsFromTip: _intOrNull(json['backwardsFromTip']),
        performedAtEpochSecs: _int(json['performedAtEpochSecs']),
      );

  final bool deleteUnconfirmed;
  final int? startHeight;
  final int? backwardsFromTip;
  final int performedAtEpochSecs;

  DateTime get performedAt =>
      DateTime.fromMillisecondsSinceEpoch(performedAtEpochSecs * 1000, isUtc: true);
}

class PaymentProofModel {
  PaymentProofModel({
    required this.txId,
    required this.proof,
    required this.raw,
  });

  factory PaymentProofModel.fromJson(Map<String, dynamic> json, {required String raw}) =>
      PaymentProofModel(
        txId: json['txId'] as int,
        proof: Map<String, dynamic>.from(json['proof'] as Map),
        raw: raw,
      );

  final int txId;
  final Map<String, dynamic> proof;
  final String raw;

  String get prettyJson => const JsonEncoder.withIndent('  ').convert(proof);
}

class PaymentProofVerification {
  PaymentProofVerification({
    required this.isSender,
    required this.isRecipient,
  });

  factory PaymentProofVerification.fromJson(Map<String, dynamic> json) =>
      PaymentProofVerification(
        isSender: json['isSender'] as bool? ?? false,
        isRecipient: json['isRecipient'] as bool? ?? false,
      );

  final bool isSender;
  final bool isRecipient;
}

class OwnerListenerStatusModel {
  OwnerListenerStatusModel({
    required this.running,
    required this.listenAddr,
    this.message,
  });

  factory OwnerListenerStatusModel.fromJson(Map<String, dynamic> json) =>
      OwnerListenerStatusModel(
        running: json['running'] as bool? ?? false,
        listenAddr: json['listenAddr'] as String? ?? '127.0.0.1:3420',
        message: json['message'] as String?,
      );

  final bool running;
  final String listenAddr;
  final String? message;
}

class TorStatusModel {
  TorStatusModel({
    required this.running,
    this.onionAddress,
    this.slatepackAddress,
  });

  factory TorStatusModel.fromJson(Map<String, dynamic> json) => TorStatusModel(
        running: json['running'] as bool? ?? false,
        onionAddress: json['onionAddress'] as String?,
        slatepackAddress: json['slatepackAddress'] as String?,
      );

  final bool running;
  final String? onionAddress;
  final String? slatepackAddress;
}
