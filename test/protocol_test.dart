import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:router_os_client/src/protocol.dart';

/// Builds the on-the-wire bytes for one API sentence (words + zero terminator).
List<int> encodeSentence(List<String> words) {
  final bytes = <int>[];
  for (final word in words) {
    final encoded = utf8.encode(word);
    bytes.addAll(encodeLength(encoded.length));
    bytes.addAll(encoded);
  }
  bytes.add(0); // end-of-sentence
  return bytes;
}

void main() {
  group('encodeLength', () {
    test('encodes single-byte lengths verbatim', () {
      expect(encodeLength(0), [0]);
      expect(encodeLength(5), [5]);
      expect(encodeLength(0x7F), [0x7F]);
    });

    test('encodes two-byte lengths with 0x8000 offset', () {
      expect(encodeLength(0x80), [0x80, 0x80]);
      expect(encodeLength(0x3FFF), [0xBF, 0xFF]);
    });

    test('encodes three-byte lengths with 0xC00000 offset', () {
      expect(encodeLength(0x4000), [0xC0, 0x40, 0x00]);
    });

    test('encodes four-byte lengths with 0xE0000000 offset', () {
      expect(encodeLength(0x200000), [0xE0, 0x20, 0x00, 0x00]);
    });

    test('encodes five-byte lengths with 0xF0 control byte', () {
      expect(encodeLength(0x10000000), [0xF0, 0x10, 0x00, 0x00, 0x00]);
    });
  });

  group('SentenceBuffer', () {
    test('extracts a complete sentence delivered in one chunk', () {
      final buffer = SentenceBuffer();
      buffer.addBytes(encodeSentence(['!re', '=name=ether1']));

      expect(buffer.nextSentence(), ['!re', '=name=ether1']);
      expect(buffer.nextSentence(), isNull);
    });

    test('extracts multiple sentences from a single chunk', () {
      final buffer = SentenceBuffer();
      buffer.addBytes([
        ...encodeSentence(['!re', '=name=ether1']),
        ...encodeSentence(['!done']),
      ]);

      expect(buffer.nextSentence(), ['!re', '=name=ether1']);
      expect(buffer.nextSentence(), ['!done']);
      expect(buffer.nextSentence(), isNull);
    });

    test('handles a sentence fragmented across byte-by-byte delivery', () {
      // Regression test for the TCP-fragmentation framing bug: a word whose
      // length prefix arrives before its body must not corrupt the stream.
      final wire = encodeSentence(['!re', '=comment=a=b=c', '=name=ether1']);
      final buffer = SentenceBuffer();

      List<String>? sentence;
      for (final byte in wire) {
        expect(buffer.nextSentence(), isNull,
            reason: 'must not emit until the sentence is complete');
        buffer.addBytes([byte]);
        sentence ??= buffer.nextSentence();
      }

      expect(sentence, ['!re', '=comment=a=b=c', '=name=ether1']);
    });

    test('handles a long word whose length prefix spans multiple bytes', () {
      final longValue = 'x' * 500; // needs a 2-byte length prefix
      final wire = encodeSentence(['=data=$longValue']);
      final buffer = SentenceBuffer();

      // Split the wire into two arbitrary fragments.
      buffer.addBytes(wire.sublist(0, 3));
      expect(buffer.nextSentence(), isNull);
      buffer.addBytes(wire.sublist(3));

      expect(buffer.nextSentence(), ['=data=$longValue']);
    });
  });

  group('parseSentence', () {
    test('keeps values that contain "=" characters', () {
      // Regression test for the data-loss bug where values with "=" were dropped.
      final parsed = parseSentence(['!re', '=key=YWJjPT0=', '=name=ether1']);

      expect(parsed['key'], 'YWJjPT0=');
      expect(parsed['name'], 'ether1');
    });

    test('skips reply markers and attribute words', () {
      final parsed = parseSentence(['!re', '.tag=42', '=id=*1']);

      expect(parsed.containsKey('tag'), isFalse);
      expect(parsed['id'], '*1');
    });

    test('keeps keys with empty values', () {
      expect(parseSentence(['=disabled=']), {'disabled': ''});
    });
  });

  group('TagGenerator', () {
    test('produces unique tags even when called in a tight loop', () {
      // Regression test for millisecond-based tag collisions.
      final gen = TagGenerator();
      final tags = <String>{};
      for (var i = 0; i < 1000; i++) {
        expect(tags.add(gen.next()), isTrue, reason: 'tags must be unique');
      }
    });
  });
}
