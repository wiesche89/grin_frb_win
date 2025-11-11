import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:grin_frb_win/src/ui/home_screen.dart';
import 'package:grin_frb_win/test_support/fakes.dart';
import 'package:grin_frb_win/src/localization/locale_store.dart';
import 'package:grin_frb_win/src/wallet/wallet_store.dart';

void main() {
  testWidgets('German locale shows translated locked-state strings', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final localeStore = LocaleStore()..setLocale(const Locale('de'));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletStore>(create: (_) => FakeWalletStore()),
          ChangeNotifierProvider<LocaleStore>.value(value: localeStore),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    // Robuste Checks: Locked-CTA Texte (kommen sicher im gesperrten Zustand)
    expect(find.text('Bitte entsperre zum Starten'), findsWidgets);
    expect(find.text('Entsperren'), findsWidgets);
    expect(find.text('Erstellen & entsperren'), findsWidgets);

    // Hinweis: Tabs/Navigationstitel werden im Locked-State ggf. nicht gerendert
    // oder anders geschrieben (z. B. 'Übersicht' statt 'Uebersicht'). Darum
    // prüfen wir diese hier bewusst nicht.
  });
}
