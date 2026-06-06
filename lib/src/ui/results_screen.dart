import 'package:flutter/material.dart';
import '../processing/hrv_calculator.dart';
import 'measurement_screen.dart';

class ResultsScreen extends StatelessWidget {
  final HrvResult hrvResult;
  final List<double> rrIntervals;

  const ResultsScreen({
    super.key,
    required this.hrvResult,
    required this.rrIntervals,
  });

  static const _primary = Color(0xFF02427A);
  static const _secondary = Color(0xFF06A3B7);
  static const _success = Color(0xFF7ACDA0);
  static const _error = Color(0xFFE57373);
  static const _warning = Color(0xFFFFA726);
  static const _textPrimary = Color(0xFF02427A);
  static const _bodyTxt = Color(0xFF64748B);
  static const _borderColor = Color(0xFFD1D5DB);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Your Results'),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildQualityBanner(),
            const SizedBox(height: 20),
            _buildHeartRateCard(),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildMetricCard(
                  label: 'RMSSD',
                  value: hrvResult.rmssd.toStringAsFixed(1),
                  unit: 'ms',
                  subtitle: 'Heart rate variability',
                )),
                const SizedBox(width: 12),
                Expanded(child: _buildMetricCard(
                  label: 'SDNN',
                  value: hrvResult.sdnn.toStringAsFixed(1),
                  unit: 'ms',
                  subtitle: 'Overall variability',
                )),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _buildMetricCard(
                  label: 'pNN50',
                  value: hrvResult.pnn50.toStringAsFixed(1),
                  unit: '%',
                )),
                const SizedBox(width: 12),
                Expanded(child: _buildMetricCard(
                  label: 'lnRMSSD',
                  value: hrvResult.lnRmssd.toStringAsFixed(2),
                  subtitle: 'Log-transformed HRV',
                )),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Total beats: ${hrvResult.totalIntervals}',
              style: const TextStyle(fontSize: 13, color: _bodyTxt),
            ),
            const SizedBox(height: 4),
            Text(
              'Mean RR interval: ${hrvResult.meanRR.round()} ms',
              style: const TextStyle(fontSize: 13, color: _bodyTxt),
            ),
            const SizedBox(height: 24),
            const Text(
              'This is not a medical device. Results are for wellness purposes '
              'only and should not be used to diagnose, treat, or prevent any disease.',
              style: TextStyle(
                fontSize: 11,
                color: _bodyTxt,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: () => _measureAgain(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _secondary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Measure Again',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _measureAgain(context),
              child: const Text(
                'Back to Start',
                style: TextStyle(color: _secondary, fontSize: 14),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _measureAgain(BuildContext context) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const MeasurementScreen()),
    );
  }

  Widget _buildQualityBanner() {
    final Color bgColor;
    final Color textColor;
    final String text;

    if (!hrvResult.isValid) {
      bgColor = _error.withOpacity(0.12);
      textColor = _error;
      text = hrvResult.qualityNote;
    } else if (hrvResult.qualityNote.contains('Short')) {
      bgColor = _warning.withOpacity(0.15);
      textColor = _warning;
      text = hrvResult.qualityNote;
    } else {
      bgColor = _success.withOpacity(0.15);
      textColor = const Color(0xFF2E7D51);
      text = 'Good Measurement \u2713';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildHeartRateCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        children: [
          const Text(
            'Heart Rate',
            style: TextStyle(fontSize: 13, color: _bodyTxt),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${hrvResult.heartRate.round()}',
                style: const TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: _textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'BPM',
                style: TextStyle(fontSize: 16, color: _bodyTxt),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required String label,
    required String value,
    String? unit,
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: _bodyTxt),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: _textPrimary,
                ),
              ),
              if (unit != null) ...[
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: const TextStyle(fontSize: 13, color: _bodyTxt),
                ),
              ],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 10, color: _bodyTxt),
            ),
          ],
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _borderColor),
      boxShadow: [
        BoxShadow(
          color: _primary.withOpacity(0.08),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
}
