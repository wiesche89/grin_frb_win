import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:grin_frb_win/src/ui/home_screen.dart';
import 'package:grin_frb_win/test_support/fakes.dart';
import 'package:grin_frb_win/src/localization/locale_store.dart';
import 'package:grin_frb_win/src/wallet/wallet_store.dart';

void main() {
  testWidgets('Locked view shows unlock call-to-action', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletStore>(create: (_) => FakeWalletStore()), // bleibt locked
          ChangeNotifierProvider<LocaleStore>(create: (_) => LocaleStore()),     // default: en
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );

    await tester.pumpAndSettle();

    // Texte aus deinem HomeScreen (via context.tr)
    expect(find.text('Please unlock to start'), findsWidgets);
    expect(find.text('Unlock'), findsWidgets);
    expect(find.text('Create & unlock'), findsWidgets);
  });
}
