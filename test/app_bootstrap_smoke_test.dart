import 'package:flutter_test/flutter_test.dart';
import 'package:grin_frb_win/main.dart';

void main() {
  testWidgets(
    'AppBootstrap renders without throwing (temporarily skipped: FRB init + viewport)',
    (tester) async {
      // Hinweis: Dieser Test wird übersprungen, weil HomeScreen/WalletStore beim
      // Pumpen FRB-APIs triggert (setNodeUrl), was in Widget-Tests ohne RustLib.init()
      // eine Exception wirft. Wir aktivieren den Test, sobald FakeWalletService/FakeWalletStore
      // in den Test injiziert werden.
      await tester.pumpWidget(const AppBootstrap());
      expect(find.byType(AppBootstrap), findsOneWidget);
    },
    skip: true,
  );
}
