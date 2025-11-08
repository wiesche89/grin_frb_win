import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:provider/provider.dart';

import 'src/localization/locale_store.dart';
import 'src/rust/frb_generated.dart/frb_generated.dart';
import 'src/ui/home_screen.dart';
import 'src/wallet/wallet_service.dart';
import 'src/wallet/wallet_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init(externalLibrary: _loadRustLib());
  runApp(const AppBootstrap());
}

ExternalLibrary _loadRustLib() {
  final base = Directory.current.path;
  const stem = 'grin_wallet_bridge';
  final suffix = Platform.isMacOS
      ? 'dylib'
      : Platform.isWindows
          ? 'dll'
          : 'so';
  final fileNames = Platform.isWindows ? [stem] : ['lib$stem'];
  final candidates = <String>[
    for (final build in ['release', 'debug'])
      for (final name in fileNames) '$base/rust/target/$build/$name.$suffix',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      return ExternalLibrary.open(path);
    }
  }
  throw ArgumentError(
    'grin_wallet_bridge.$suffix not found. Please build the Rust project first (cargo build --release).',
  );
}

class AppBootstrap extends StatelessWidget {
  const AppBootstrap({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => WalletStore(WalletService())),
        ChangeNotifierProvider(create: (_) => LocaleStore()),
      ],
      child: const _MaterialHost(),
    );
  }
}

class _MaterialHost extends StatelessWidget {
  const _MaterialHost();

  @override
  Widget build(BuildContext context) {
    final localeStore = context.watch<LocaleStore>();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: localeStore.locale,
      supportedLocales: const [Locale('en'), Locale('de')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      title: 'Grin Wallet Studio',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F17),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
