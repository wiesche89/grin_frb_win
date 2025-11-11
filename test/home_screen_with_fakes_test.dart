// test/home_screen_with_fakes_test.dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:grin_frb_win/src/ui/home_screen.dart';
import 'package:grin_frb_win/test_support/fakes.dart';
import 'package:grin_frb_win/src/localization/locale_store.dart';
import 'package:grin_frb_win/src/wallet/wallet_store.dart';

void main() {
  testWidgets('HomeScreen renders with fake stores (no FRB calls)', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<WalletStore>(create: (_) => FakeWalletStore()),
          ChangeNotifierProvider<LocaleStore>(create: (_) => LocaleStore()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: const HomeScreen(),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
            scaffoldBackgroundColor: const Color(0xFF0F0F17),
            useMaterial3: true,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
