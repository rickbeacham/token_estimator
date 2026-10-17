import 'package:flutter_test/flutter_test.dart';
// Update 'token_estimator' below to match the `name:` field in your pubspec.yaml
import 'package:token_estimator/data/catalog_repository.dart';
import 'package:token_estimator/engine/simulator.dart';
import 'package:token_estimator/engine/tokenizer.dart';
import 'package:token_estimator/pricing/model_pricing.dart';

void main() {
  const engine = SimulationEngine();

  setUp(() {
    TokenizerEngine.clearCache();
  });

  group('Endpoint & Surrogate Truncation Safety', () {
    test('openRouterModelsUri resolves to valid HTTPS host and path', () {
      expect(openRouterModelsUri.scheme, equals('https'));
      expect(openRouterModelsUri.host, equals('openrouter.ai'));
      expect(openRouterModelsUri.path, equals(kOpenRouterModelsPath));
      expect(openRouterModelsUri.toString(), isNot(contains('[')));
    });

    test('capInput does not split a UTF-16 surrogate pair at maxInputChars boundary', () {
      // Place a 2-code-unit emoji ('🚀', \uD83D\uDE80) straddling index 199,999..200,000
      final prefix = 'a' * (TokenizerEngine.maxInputChars - 1);
      final input = '$prefix🚀tail';

      final capped = TokenizerEngine.capInput(input);
      expect(capped.length, equals(TokenizerEngine.maxInputChars - 1));
      final lastUnit = capped.codeUnitAt(capped.length - 1);
      expect(lastUnit < 0xD800 || lastUnit > 0xDBFF, isTrue);
    });
  });

  group('TokenizerEngine BPE Heuristics & Emoji ZWJ Grouping', () {
    test('Groups multi-char operators as single tokens', () {
      final spans = TokenizerEngine.tokenizeToSpans('a === b && c -> d');
      final punctSpans = spans
          .where((s) => s.kind == TokenKind.codePunct)
          .toList();
      expect(punctSpans.map((s) => s.text), containsAll(['===', '&&', '->']));
    });

    test('Collapses ZWJ family emoji and flag pairs into single spans', () {
      expect(TokenizerEngine.estimateTokenCount('🇺🇸'), equals(3));
      expect(TokenizerEngine.estimateTokenCount('👨‍👩‍👧‍👦'), equals(4));
    });
  });

  group('SimulationEngine & SimulationRequest Value Object', () {
    final claude = kDefaultModelCatalog.firstWhere(
      (m) => m.id == 'claude-sonnet',
    );

    final baseFixture = SimulationRequest(
      model: claude,
      systemText: 'System instructions ' * 200,
      userText: 'Initial task',
      mode: ExecutionMode.agent,
      reasoningEffort: ReasoningPreset.off,
      agentSteps: 1,
      toolPayloadTokensPerStep: 500,
      visibleOutputTokensPerStep: 200,
      contextCachingEnabled: true,
      imageCount: 1,
    );

    test('1-Turn Agent Loop with +25% cache write surcharge reports negative cacheImpactPercent', () {
      final sim = engine.simulate(baseFixture);

      expect(sim.totalCacheWriteTokens, greaterThan(0));
      expect(sim.totalCachedReadTokens, equals(0));
      expect(sim.cacheImpactPercent, lessThan(0.0));
    });

    test(
      'Multi-turn Agent Loop via copyWith reports positive cacheImpactPercent',
      () {
        final multiTurnReq = baseFixture.copyWith(
          reasoningEffort: ReasoningPreset.low,
          agentSteps: 6,
          toolPayloadTokensPerStep: 1000,
          visibleOutputTokensPerStep: 300,
          imageCount: 2,
        );

        final sim = engine.simulate(multiTurnReq);

        expect(sim.turns.length, equals(6));
        expect(
          sim.turns.first.cacheWriteTokens,
          equals(sim.totalCacheWriteTokens),
        );
        expect(sim.turns[1].cacheWriteTokens, equals(0));
        expect(sim.turns[1].cacheReadTokens, equals(sim.totalCacheWriteTokens));
        expect(sim.cacheImpactPercent, greaterThan(20.0));
      },
    );

    test(
      'Supports custom injected TokenizerFn for deterministic unit testing',
      () {
        final fixedTokenizerEngine = SimulationEngine(
          tokenizer: (text, {charsPerToken = 3.8}) => 100,
        );
        final sim = fixedTokenizerEngine.simulate(
          baseFixture.copyWith(imageCount: 0),
        );
        expect(sim.systemTextTokens, equals(100));
        expect(sim.userTextTokens, equals(100));
      },
    );
  });
}
