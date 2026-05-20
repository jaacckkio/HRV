/// A fixed-size circular buffer for efficient sliding window operations.
/// Adapted from flutter_ppg (MIT License, shigindo.com)
class RingBuffer<T> {
  final List<T?> _buffer;
  final int capacity;
  int _head = 0;
  int _length = 0;

  RingBuffer(this.capacity) : _buffer = List<T?>.filled(capacity, null);

  void add(T element) {
    _buffer[_head] = element;
    _head = (_head + 1) % capacity;
    if (_length < capacity) {
      _length++;
    }
  }

  bool get isFull => _length == capacity;

  int get length => _length;

  /// Returns the elements in insertion order (oldest to newest).
  List<T> get toList {
    if (_length == 0) return [];

    if (_length < capacity) {
      return _buffer.sublist(0, _length).cast<T>();
    }

    final result = <T>[];
    for (int i = 0; i < capacity; i++) {
      result.add(_buffer[(_head + i) % capacity] as T);
    }
    return result;
  }

  void clear() {
    _head = 0;
    _length = 0;
  }
}
