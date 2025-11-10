import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'locale_store.dart';

extension LocalizationX on BuildContext {
  LocaleStore get _watchLocaleStore => read<LocaleStore>();
  LocaleStore get _readLocaleStore => read<LocaleStore>();

  String tr(String en, String de) => _watchLocaleStore.isGerman ? de : en;

  String trNow(String en, String de) => _readLocaleStore.isGerman ? de : en;
}
