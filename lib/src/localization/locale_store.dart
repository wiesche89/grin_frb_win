import 'package:flutter/material.dart';

class LocaleStore extends ChangeNotifier {
  Locale _locale = const Locale('en');

  Locale get locale => _locale;
  bool get isGerman => _locale.languageCode == 'de';

  void setLocale(Locale locale) {
    if (_locale == locale) return;
    _locale = locale;
    notifyListeners();
  }

  void toggle() => setLocale(isGerman ? const Locale('en') : const Locale('de'));
}
