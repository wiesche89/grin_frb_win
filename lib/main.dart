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
  try {
    await RustLib.init(externalLibrary: _loadRustLib());
    runApp(const AppBootstrap());
  } catch (e, st) {
    await _writeStartupLog('Failed to load Rust DLL', e, st);
    runApp(_ErrorApp(error: e.toString()));
  }
}

ExternalLibrary _loadRustLib() {
  final base = Directory.current.path;
  // Try resolving the path of the running executable (works for desktop apps)
  String? exeDir;
  try {
    exeDir = File(Platform.resolvedExecutable).parent.path;
  } catch (_) {
    exeDir = null;
  }
  const stem = 'grin_wallet_bridge';
  final suffix = Platform.isMacOS
      ? 'dylib'
      : Platform.isWindows
          ? 'dll'
          : 'so';
  final fileNames = Platform.isWindows ? [stem] : ['lib$stem'];
  final candidates = <String>[
    // 1) Relative to current working directory (repo root during `flutter run`)
    for (final build in ['release', 'debug'])
      for (final name in fileNames) '$base/rust/target/$build/$name.$suffix',
    // 2) Next to the executable (double-click scenario)
    if (exeDir != null) for (final name in fileNames) '$exeDir/$name.$suffix',
    // 3) Native assets folder installed by CMake (if present)
    if (exeDir != null && Platform.isWindows)
      for (final name in fileNames)
        '$exeDir/native_assets/windows/$name.$suffix',
    if (exeDir != null && Platform.isMacOS)
      for (final name in fileNames)
        '$exeDir/../Frameworks/$name.$suffix',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) {
      _writeStartupLog('Loaded Rust DLL', path, null);
      return ExternalLibrary.open(path);
    }
  }
  _writeStartupLog('Rust DLL not found', candidates, null);
  throw ArgumentError(
    '''grin_wallet_bridge.$suffix not found. Looked in:
 - repo-relative rust/target/(release|debug)
 - next to the exe
 - native_assets folder (if present)
 Please copy grin_wallet_bridge.dll next to the exe or build it with cargo build --release.''',
  );
}

Future<void> _writeStartupLog(String title, Object? details, StackTrace? st) async {
  try {
    final ts = DateTime.now().toIso8601String();
    final exe = Platform.resolvedExecutable;
    final exeDir = File(exe).parent.path;
    final cwd = Directory.current.path;
    final logPath = Platform.isWindows
        ? '$exeDir/startup.log'
        : '$cwd/startup.log';
    final lines = <String>[
      '[$ts] $title',
      'exe:  $exe',
      'dir:  $exeDir',
      'cwd:  $cwd',
      if (details != null) 'details: $details',
      if (st != null) 'stack: $st',
      '---',
    ];
    final file = File(logPath);
    await file.writeAsString(lines.join('\n') + '\n', mode: FileMode.append);
  } catch (_) {
    // Ignore logging failures.
  }
}

class _ErrorApp extends StatelessWidget {
  const _ErrorApp({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Startup Error',
      home: Scaffold(
        backgroundColor: const Color(0xFF0F0F17),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Grin Wallet Studio – Fehler beim Start',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Die native Rust‑Bibliothek konnte nicht geladen werden.',
                ),
                const SizedBox(height: 8),
                Text(error, style: const TextStyle(color: Colors.orangeAccent)),
                const SizedBox(height: 12),
                const Text(
                  'Siehe startup.log im Programmordner für Details.',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
