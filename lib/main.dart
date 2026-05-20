import 'package:flutter/material.dart';
import 'src/ui/measurement_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VagalHRVApp());
}

class VagalHRVApp extends StatelessWidget {
  const VagalHRVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Vagal HRV Camera',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF02427A),
        useMaterial3: true,
      ),
      home: const MeasurementScreen(),
    );
  }
}
