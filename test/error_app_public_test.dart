import 'package:flutter_test/flutter_test.dart';
import 'package:grin_frb_win/test_support/error_app_public.dart';

void main() {
  testWidgets('ErrorAppPublic shows headline and error text', (tester) async {
    const msg = 'DLL missing';
    await tester.pumpWidget(const ErrorAppPublic(error: msg));

    expect(find.textContaining('Fehler beim Start'), findsOneWidget);
    expect(find.textContaining('Rust'), findsOneWidget);
    expect(find.textContaining(msg), findsOneWidget);
    expect(find.textContaining('startup.log'), findsOneWidget);
  });
}
