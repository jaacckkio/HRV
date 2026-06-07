import '../models/filter_result.dart';
import '../models/ppg_config.dart';

/// Filters RR intervals to remove artifacts and noise.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class OutlierFilter {
  final double minRRMs;
  final double maxRRMs;
  final double maxAdjacentChangeRatio;

  const OutlierFilter({
    required this.minRRMs,
    required this.maxRRMs,
    required this.maxAdjacentChangeRatio,
  }) : assert(minRRMs > 0),
       assert(maxRRMs > minRRMs),
       assert(maxAdjacentChangeRatio >= 0);

  factory OutlierFilter.fromConfig(PPGConfig config) {
    return OutlierFilter(
      minRRMs: 400.0,
      maxRRMs: 1600.0,
      maxAdjacentChangeRatio: config.maxAdjacentRRChangeRatio,
    );
  }

  List<double> filterOutliers(List<double> rrIntervals) {
    return filterOutliersWithStats(rrIntervals).intervals;
  }

  FilterResult filterOutliersWithStats(List<double> rrIntervals) {
    if (rrIntervals.isEmpty) {
      return const FilterResult(
          intervals: [], totalInput: 0, rejectedCount: 0, rejectionRatio: 0.0);
    }

    int rejected = 0;
    final totalInput = rrIntervals.length;

    // 1. Physiological filter
    var filtered = <double>[];
    for (final rr in rrIntervals) {
      if (rr >= minRRMs && rr <= maxRRMs) {
        filtered.add(rr);
      } else {
        rejected++;
      }
    }

    // 2. Adjacent interval validation
    if (filtered.length >= 2) {
      final adjacentFiltered = <double>[filtered[0]];
      for (int i = 1; i < filtered.length; i++) {
        final prev = adjacentFiltered.last;
        final curr = filtered[i];
        final changeRatio = (curr - prev).abs() / prev;

        if (changeRatio <= maxAdjacentChangeRatio) {
          adjacentFiltered.add(curr);
        } else {
          rejected++;
        }
      }
      filtered = adjacentFiltered;
    }

    // 3. Malik method — reject intervals deviating >20% from local average
    if (filtered.length >= 3) {
      final keep = List<bool>.filled(filtered.length, true);
      for (int i = 0; i < filtered.length; i++) {
        final start = i - 2 < 0 ? 0 : i - 2;
        final end = i + 2 >= filtered.length ? filtered.length - 1 : i + 2;
        double localSum = 0.0;
        int localCount = 0;
        for (int j = start; j <= end; j++) {
          localSum += filtered[j];
          localCount++;
        }
        final localMean = localSum / localCount;
        if ((filtered[i] - localMean).abs() / localMean > 0.20) {
          keep[i] = false;
          rejected++;
        }
      }
      final malikFiltered = <double>[];
      for (int i = 0; i < filtered.length; i++) {
        if (keep[i]) malikFiltered.add(filtered[i]);
      }
      filtered = malikFiltered;
    }

    // 4. Median-based filter: reject intervals >30% from median
    if (filtered.length >= 3) {
      final sorted = List<double>.from(filtered)..sort();
      final median = sorted[sorted.length ~/ 2];
      final medianFiltered = <double>[];
      for (final rr in filtered) {
        if ((rr - median).abs() / median <= 0.30) {
          medianFiltered.add(rr);
        } else {
          rejected++;
        }
      }
      filtered = medianFiltered;
    }

    // 5. IQR filter
    if (filtered.length >= 4) {
      final beforeIQR = filtered.length;
      filtered = _applyIQRMethod(filtered);
      rejected += beforeIQR - filtered.length;
    }

    return FilterResult(
      intervals: filtered,
      totalInput: totalInput,
      rejectedCount: rejected,
      rejectionRatio: totalInput > 0 ? rejected / totalInput : 0.0,
    );
  }

  List<double> _applyIQRMethod(List<double> data) {
    if (data.isEmpty) return [];

    final sorted = List<double>.from(data)..sort();
    final q1 = _percentile(sorted, 25);
    final q3 = _percentile(sorted, 75);
    final iqr = q3 - q1;

    final lowerBound = q1 - 1.5 * iqr;
    final upperBound = q3 + 1.5 * iqr;

    return data.where((val) => val >= lowerBound && val <= upperBound).toList();
  }

  double _percentile(List<double> sortedData, int percentile) {
    if (sortedData.isEmpty) return 0.0;

    final n = sortedData.length;
    final index = (percentile / 100) * (n - 1);
    final lower = index.floor();
    final upper = index.ceil();

    if (lower == upper) return sortedData[lower];

    final weight = index - lower;
    return sortedData[lower] * (1 - weight) + sortedData[upper] * weight;
  }
}
