import 'dart:convert';

/// Pure, I/O-free implementation of the RouterOS API wire protocol.
///
/// The RouterOS API frames data as a series of *sentences*. Each sentence is a
/// list of length-prefixed *words* terminated by a zero-length word. This file
/// contains only the encoding/decoding logic so it can be tested without a
/// socket or a real router.

/// Exception thrown when a word's encoded length exceeds the protocol maximum.
class WordTooLong implements Exception {
  /// The error message associated with the long word error.
  final String message;

  /// Creates a [WordTooLong] exception with the given error [message].
  WordTooLong(this.message);

  @override
  String toString() => message;
}

/// Encodes [length] using the RouterOS API control-byte length scheme.
///
/// Lengths are written big-endian with a variable-width prefix that doubles as
/// a marker for how many bytes follow.
List<int> encodeLength(int length) {
  if (length < 0) {
    throw WordTooLong('Length cannot be negative: $length');
  }
  if (length < 0x80) {
    return [length];
  } else if (length < 0x4000) {
    return _toBytes(length | 0x8000, 2);
  } else if (length < 0x200000) {
    return _toBytes(length | 0xC00000, 3);
  } else if (length < 0x10000000) {
    return _toBytes(length | 0xE0000000, 4);
  } else if (length < 0x100000000) {
    return [0xF0, ..._toBytes(length, 4)];
  } else {
    throw WordTooLong('Word is too long. Max length is 4294967295.');
  }
}

/// Big-endian byte expansion of [value] into [byteCount] bytes.
List<int> _toBytes(int value, int byteCount) {
  final result = <int>[];
  for (var i = 0; i < byteCount; i++) {
    result.add((value >> (8 * (byteCount - i - 1))) & 0xFF);
  }
  return result;
}

/// Result of decoding a length prefix: the decoded [value] and the buffer
/// offset immediately after the prefix bytes.
class _LengthDecode {
  final int value;
  final int nextOffset;

  _LengthDecode(this.value, this.nextOffset);
}

/// Accumulates incoming socket bytes and extracts complete sentences.
///
/// Crucially, bytes are only consumed once a *whole* sentence is available.
/// A word whose length prefix has arrived but whose body has not (a normal
/// consequence of TCP fragmentation) leaves the buffer untouched, so the next
/// chunk resumes parsing correctly instead of corrupting the stream.
class SentenceBuffer {
  final List<int> _buffer = [];

  /// Appends freshly received [bytes] to the internal buffer.
  void addBytes(List<int> bytes) => _buffer.addAll(bytes);

  /// Returns the next complete sentence, or `null` if one is not yet fully
  /// buffered. Call repeatedly until it returns `null` to drain the buffer.
  List<String>? nextSentence() {
    final words = <String>[];
    var offset = 0;

    while (true) {
      final decoded = _decodeLengthAt(offset);
      if (decoded == null) {
        return null; // Not enough bytes for the length prefix yet.
      }

      if (decoded.value == 0) {
        // Zero-length word terminates the sentence. Consume it and return.
        _buffer.removeRange(0, decoded.nextOffset);
        return words;
      }

      final wordEnd = decoded.nextOffset + decoded.value;
      if (_buffer.length < wordEnd) {
        return null; // Word body not fully buffered yet.
      }

      words.add(utf8.decode(_buffer.sublist(decoded.nextOffset, wordEnd)));
      offset = wordEnd;
    }
  }

  /// Decodes the length prefix starting at [offset], or `null` if the prefix
  /// bytes have not all arrived yet.
  _LengthDecode? _decodeLengthAt(int offset) {
    if (offset >= _buffer.length) return null;
    final first = _buffer[offset];

    if (first < 0x80) {
      return _LengthDecode(first, offset + 1);
    } else if (first < 0xC0) {
      if (offset + 1 >= _buffer.length) return null;
      final value = ((first << 8) | _buffer[offset + 1]) - 0x8000;
      return _LengthDecode(value, offset + 2);
    } else if (first < 0xE0) {
      if (offset + 2 >= _buffer.length) return null;
      final value = ((first << 16) |
              (_buffer[offset + 1] << 8) |
              _buffer[offset + 2]) -
          0xC00000;
      return _LengthDecode(value, offset + 3);
    } else if (first < 0xF0) {
      if (offset + 3 >= _buffer.length) return null;
      final value = ((first << 24) |
              (_buffer[offset + 1] << 16) |
              (_buffer[offset + 2] << 8) |
              _buffer[offset + 3]) -
          0xE0000000;
      return _LengthDecode(value, offset + 4);
    } else if (first == 0xF0) {
      if (offset + 4 >= _buffer.length) return null;
      final value = (_buffer[offset + 1] << 24) |
          (_buffer[offset + 2] << 16) |
          (_buffer[offset + 3] << 8) |
          _buffer[offset + 4];
      return _LengthDecode(value, offset + 5);
    } else {
      throw WordTooLong('Received word is too long.');
    }
  }
}

/// Parses a reply [sentence] into key/value pairs.
///
/// Reply markers (`!re`, `!done`, ...) and API attribute words (`.tag=...`) are
/// ignored. Each `=key=value` word is split on its *first* `=` only, so values
/// that themselves contain `=` (base64, comments, URLs) are preserved intact.
Map<String, String> parseSentence(List<String> sentence) {
  final parsed = <String, String>{};
  for (final word in sentence) {
    if (word.isEmpty || word.startsWith('!')) continue;
    if (word.startsWith('=')) {
      final body = word.substring(1);
      final separator = body.indexOf('=');
      if (separator >= 0) {
        parsed[body.substring(0, separator)] = body.substring(separator + 1);
      }
    }
    // Words starting with '.' (e.g. '.tag') are attributes, handled elsewhere.
  }
  return parsed;
}

/// Generates strictly increasing, collision-free command tags.
///
/// Replaces the previous millisecond-timestamp scheme, which collided when
/// several commands were issued within the same millisecond.
class TagGenerator {
  int _counter = 0;

  /// Returns the next unique tag.
  String next() => (++_counter).toString();
}
