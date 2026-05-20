/// Result of RR interval filtering with statistics.
class FilterResult {
  final List<double> intervals;
  final int totalInput;
  final int rejectedCount;
  final double rejectionRatio;

  const FilterResult({
    required this.intervals,
    required this.totalInput,
    required this.rejectedCount,
    required this.rejectionRatio,
  });

  bool get isQualityAcceptable => rejectionRatio < 0.20;
}
