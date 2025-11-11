import 'package:flutter/material.dart';

/// Lightweight copy of your startup error UI so tests can exercise the layout
/// without needing to make _ErrorApp public in main.dart.
class ErrorAppPublic extends StatelessWidget {
  const ErrorAppPublic({super.key, required this.error});
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
                const Text('Die native Rust-Bibliothek konnte nicht geladen werden.'),
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
