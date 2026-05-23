import 'package:flutter/material.dart';
import 'reader_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BookReaderApp());
}

class BookReaderApp extends StatelessWidget {
  const BookReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Book Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2C2C2A),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2C2C2A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const ReaderScreen(),
    );
  }
}
