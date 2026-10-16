import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

// ============================================================================
// TOKENIZER ENGINE (SINGLE RESPONSIBILITY: TEXT -> WEIGHTED BPE SPANS)
// ============================================================================

enum TokenKind { word, codePunct, number, whitespace, emojiOrNonLatin }

class TokenSpanItem {
  final String text;
  final TokenKind kind;
  final int bpeWeight;
  const TokenSpanItem(this.text, this.kind, {this.bpeWeight = 1});
}

class TokenizerEngine {
  static const int maxInputChars = 200000;
  static const int _maxCacheEntries = 64;

  static final LinkedHashMap<String, int> _countCache =
      LinkedHashMap<String, int>();

  /// Clears the static token count LRU cache (useful for isolated widget/unit tests).
  @visibleForTesting
  static void clearCache() => _countCache.clear();

  /// Unicode-aware regex handling:
  /// 1: Whitespace runs
  /// 2: Numeric literals
  /// 3: Multi-char code operators & markdown fences
  /// 4: ASCII & Latin/Cyrillic identifiers
  /// 5: CJK ideographs & Hangul syllables
  /// 6: Complete Emoji clusters (Regional Indicator pairs, ZWJ sequences,
  ///    skin-tone modifiers \u{1F3FB}-\u{1F3FF}, and variation selectors \uFE0F)
  /// 7: Standalone zero-width joiners / variation selectors (weight 0)
  /// 8: Single-char punctuation fallback
  static final RegExp _tokenRegex = RegExp(
    r'(\s+)'
    r'|([0-9]+(?:\.[0-9]+)?)'
    r'|(```|===|!==|>>>|<<|>>|->|=>|::|\|\||&&|<=|>=|==|!=|\+\+|--)'
    r'|([A-Za-z_\u00C0-\u024F\u0400-\u04FF][A-Za-z0-9_\u00C0-\u024F\u0400-\u04FF]*)'
    r'|([\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uAC00-\uD7AF])'
    r'|([\u{1F1E6}-\u{1F1FF}]{2}|(?:[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}][\u{1F3FB}-\u{1F3FF}\uFE0F]?(?:\u200D[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}][\u{1F3FB}-\u{1F3FF}\uFE0F]?)*))'
    r'|([\u200D\uFE0F]+)'
    r'|([^\sA-Za-z0-9_])',
    unicode: true,
  );

  /// Truncates input at [maxInputChars] UTF-16 code units without splitting
  /// a surrogate pair across the boundary.
  static String capInput(String text) {
    if (text.length <= maxInputChars) return text;
    int end = maxInputChars;
    if (end > 0 && end < text.length) {
      final int cu = text.codeUnitAt(end - 1);
      if (cu >= 0xD800 && cu <= 0xDBFF) {
        end -= 1;
      }
    }
    return text.substring(0, end);
  }

  /// Content-aware subword tokenizer that handles multi-char operators,
  /// Cyrillic/CJK scripts, and grouped ZWJ/flag emoji sequences.
  static List<TokenSpanItem> tokenizeToSpans(
    String rawText, {
    double charsPerToken = 3.8,
  }) {
    if (rawText.isEmpty) return const [];
    final text = capInput(rawText);
    final List<TokenSpanItem> spans = [];
    final matches = _tokenRegex.allMatches(text);
    final int subwordChunk = math.max(3, charsPerToken.round() + 1);

    for (final m in matches) {
      final full = m.group(0)!;
      if (m.group(1) != null) {
        // Whitespace run: collapses multiple spaces into ~1 token per 4 chars
        if (full.length <= 4) {
          spans.add(TokenSpanItem(full, TokenKind.whitespace));
        } else {
          for (int i = 0; i < full.length; i += 4) {
            spans.add(TokenSpanItem(
              full.substring(i, math.min(i + 4, full.length)),
              TokenKind.whitespace,
            ));
          }
        }
      } else if (m.group(2) != null) {
        // Numbers: usually 1-3 digits per token
        for (int i = 0; i < full.length; i += 3) {
          spans.add(TokenSpanItem(
            full.substring(i, math.min(i + 3, full.length)),
            TokenKind.number,
          ));
        }
      } else if (m.group(3) != null) {
        // Grouped multi-char operator or code fence = 1 token
        spans.add(TokenSpanItem(full, TokenKind.codePunct));
      } else if (m.group(4) != null) {
        // Words / identifiers: split long words into BPE-like subwords
        // Cyrillic / non-ASCII words split slightly denser in BPE
        final bool isNonAscii = full.codeUnits.any((c) => c > 127);
        final int step =
            isNonAscii ? math.max(2, subwordChunk - 1) : subwordChunk;
        if (full.length <= step + 2) {
          spans.add(TokenSpanItem(full, TokenKind.word));
        } else {
          for (int i = 0; i < full.length; i += step) {
            spans.add(TokenSpanItem(
              full.substring(i, math.min(i + step, full.length)),
              TokenKind.word,
            ));
          }
        }
      } else if (m.group(5) != null) {
        // CJK character (~1.5-2 BPE tokens)
        spans.add(TokenSpanItem(full, TokenKind.emojiOrNonLatin, bpeWeight: 2));
      } else if (m.group(6) != null) {
        // Complete Emoji or ZWJ/Flag cluster: 3 tokens for single/flag, 4 for composite ZWJ
        final int weight = full.contains('\u200D') ? 4 : 3;
        spans.add(
          TokenSpanItem(full, TokenKind.emojiOrNonLatin, bpeWeight: weight),
        );
      } else if (m.group(7) != null) {
        // Stray zero-width joiners or variation selectors carry 0 standalone token weight
        continue;
      } else {
        // Code punctuation / symbols
        spans.add(TokenSpanItem(full, TokenKind.codePunct));
      }
    }
    return spans;
  }

  /// Memoized token count with an LRU cache keyed on (hashCode, length, charsPerToken).
  static int estimateTokenCount(String rawText, {double charsPerToken = 3.8}) {
    final text = capInput(rawText);
    if (text.trim().isEmpty) return 0;

    final String cacheKey =
        '${text.hashCode}:${text.length}:${charsPerToken.toStringAsFixed(2)}';
    final int? cached = _countCache.remove(cacheKey);
    if (cached != null) {
      _countCache[cacheKey] = cached; // Refresh LRU order
      return cached;
    }

    final spans = tokenizeToSpans(text, charsPerToken: charsPerToken);
    // In BPE/SentencePiece, a leading space usually merges with the following word
    int count = 0;
    bool prevWasSpace = false;
    for (final s in spans) {
      if (s.kind == TokenKind.whitespace) {
        if (prevWasSpace || s.text.contains('\n')) {
          count++;
        }
        prevWasSpace = true;
      } else {
        count += s.bpeWeight;
        prevWasSpace = false;
      }
    }

    final int result = math.max(1, count);
    if (_countCache.length >= _maxCacheEntries) {
      _countCache.remove(_countCache.keys.first);
    }
    _countCache[cacheKey] = result;
    return result;
  }
}