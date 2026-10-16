import 'dart:math' as math;

import '../pricing/model_pricing.dart';
import 'tokenizer.dart';

// ============================================================================
// SIMULATION REQUEST, RESULT MODELS & ENGINE
// ============================================================================

typedef TokenizerFn = int Function(String text, {double charsPerToken});

class SimulationRequest {
  final ModelPricing model;
  final String systemText;
  final String userText;
  final ExecutionMode mode;
  final ReasoningPreset reasoningEffort;
  final int agentSteps;
  final int toolPayloadTokensPerStep;
  final int visibleOutputTokensPerStep;
  final bool contextCachingEnabled;
  final int imageCount;
  final int pdfPageCount;
  final int mediaMinutes;

  const SimulationRequest({
    required this.model,
    required this.systemText,
    required this.userText,
    required this.mode,
    required this.reasoningEffort,
    required this.agentSteps,
    required this.toolPayloadTokensPerStep,
    required this.visibleOutputTokensPerStep,
    required this.contextCachingEnabled,
    this.imageCount = 0,
    this.pdfPageCount = 0,
    this.mediaMinutes = 0,
  });

  SimulationRequest copyWith({
    ModelPricing? model,
    String? systemText,
    String? userText,
    ExecutionMode? mode,
    ReasoningPreset? reasoningEffort,
    int? agentSteps,
    int? toolPayloadTokensPerStep,
    int? visibleOutputTokensPerStep,
    bool? contextCachingEnabled,
    int? imageCount,
    int? pdfPageCount,
    int? mediaMinutes,
  }) {
    return SimulationRequest(
      model: model ?? this.model,
      systemText: systemText ?? this.systemText,
      userText: userText ?? this.userText,
      mode: mode ?? this.mode,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      agentSteps: agentSteps ?? this.agentSteps,
      toolPayloadTokensPerStep:
          toolPayloadTokensPerStep ?? this.toolPayloadTokensPerStep,
      visibleOutputTokensPerStep:
          visibleOutputTokensPerStep ?? this.visibleOutputTokensPerStep,
      contextCachingEnabled:
          contextCachingEnabled ?? this.contextCachingEnabled,
      imageCount: imageCount ?? this.imageCount,
      pdfPageCount: pdfPageCount ?? this.pdfPageCount,
      mediaMinutes: mediaMinutes ?? this.mediaMinutes,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SimulationRequest &&
          other.model.id == model.id &&
          other.systemText == systemText &&
          other.userText == userText &&
          other.mode == mode &&
          other.reasoningEffort == reasoningEffort &&
          other.agentSteps == agentSteps &&
          other.toolPayloadTokensPerStep == toolPayloadTokensPerStep &&
          other.visibleOutputTokensPerStep == visibleOutputTokensPerStep &&
          other.contextCachingEnabled == contextCachingEnabled &&
          other.imageCount == imageCount &&
          other.pdfPageCount == pdfPageCount &&
          other.mediaMinutes == mediaMinutes);

  @override
  int get hashCode => Object.hash(
        model.id,
        systemText,
        userText,
        mode,
        reasoningEffort,
        agentSteps,
        toolPayloadTokensPerStep,
        visibleOutputTokensPerStep,
        contextCachingEnabled,
        imageCount,
        pdfPageCount,
        mediaMinutes,
      );
}

class TurnBreakdown {
  final int turnNumber;
  final int totalContextTokens;
  final int uncachedInputTokens;

  /// Populated on Turn 1 only when context caching is active (0 on Turn 2..N).
  final int cacheWriteTokens;

  /// Populated on Turn 2..N when reading from the cached prefix (0 on Turn 1).
  final int cacheReadTokens;
  final int outputTokens;
  final int reasoningTokens;
  final double turnCost;
  final bool isLongContextTier;

  const TurnBreakdown({
    required this.turnNumber,
    required this.totalContextTokens,
    required this.uncachedInputTokens,
    required this.cacheWriteTokens,
    required this.cacheReadTokens,
    required this.outputTokens,
    required this.reasoningTokens,
    required this.turnCost,
    required this.isLongContextTier,
  });
}

class SimulationBreakdown {
  final ModelPricing model;
  final int systemTextTokens;
  final int userTextTokens;
  final int multimodalTokens;
  final int initialPromptTokens;
  final int peakTurnContextTokens;
  final int totalBilledInputTokens; // Strictly uncached input tokens
  final int totalCacheWriteTokens; // Turn-1 only cache write tokens
  final int totalCachedReadTokens; // Turn 2..N cache read tokens
  final int totalVisibleOutputTokens;
  final int totalReasoningTokens;
  final bool exceedsContextWindow;
  final bool crossedLongContextTier;
  final bool textWasTruncated;

  final double uncachedInputCost;
  final double cacheWriteCost;
  final double cacheReadCost;
  final double visibleOutputCost;
  final double reasoningOutputCost;
  final double totalCostSingleRun;
  final double uncachedBaselineCost;
  final double uncachedInputBaselineCost;
  final List<TurnBreakdown> turns;

  const SimulationBreakdown({
    required this.model,
    required this.systemTextTokens,
    required this.userTextTokens,
    required this.multimodalTokens,
    required this.initialPromptTokens,
    required this.peakTurnContextTokens,
    required this.totalBilledInputTokens,
    required this.totalCacheWriteTokens,
    required this.totalCachedReadTokens,
    required this.totalVisibleOutputTokens,
    required this.totalReasoningTokens,
    required this.exceedsContextWindow,
    required this.crossedLongContextTier,
    required this.textWasTruncated,
    required this.uncachedInputCost,
    required this.cacheWriteCost,
    required this.cacheReadCost,
    required this.visibleOutputCost,
    required this.reasoningOutputCost,
    required this.totalCostSingleRun,
    required this.uncachedBaselineCost,
    required this.uncachedInputBaselineCost,
    required this.turns,
  });

  /// Signed input-cost impact of context caching:
  /// - Positive (+X%) = Cache saved X% of uncached input baseline cost.
  /// - Negative (-X%) = Cache penalty increased input cost by X% (e.g. 1-turn write surcharge).
  double get cacheImpactPercent {
    if (uncachedInputBaselineCost <= 0) return 0.0;
    final actualInputCost = uncachedInputCost + cacheWriteCost + cacheReadCost;
    final diff = uncachedInputBaselineCost - actualInputCost;
    return (diff / uncachedInputBaselineCost) * 100.0;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SimulationBreakdown &&
          other.model.id == model.id &&
          other.totalCostSingleRun == totalCostSingleRun &&
          other.peakTurnContextTokens == peakTurnContextTokens &&
          other.totalBilledInputTokens == totalBilledInputTokens &&
          other.totalCacheWriteTokens == totalCacheWriteTokens &&
          other.totalCachedReadTokens == totalCachedReadTokens);

  @override
  int get hashCode => Object.hash(
        model.id,
        totalCostSingleRun,
        peakTurnContextTokens,
        totalBilledInputTokens,
        totalCacheWriteTokens,
        totalCachedReadTokens,
      );
}

class SimulationEngine {
  final TokenizerFn tokenizer;

  const SimulationEngine({
    this.tokenizer = TokenizerEngine.estimateTokenCount,
  });

  // --------------------------------------------------------------------------
  // EXACT TURN-BY-TURN AGENT & CHAT SIMULATION ENGINE
  // --------------------------------------------------------------------------

  SimulationBreakdown simulate(SimulationRequest req) {
    final model = req.model;
    final bool truncated =
        req.systemText.length > TokenizerEngine.maxInputChars ||
        req.userText.length > TokenizerEngine.maxInputChars;

    final int sysTokens = tokenizer(
      req.systemText,
      charsPerToken: model.charsPerToken,
    );
    final int usrTokens = tokenizer(
      req.userText,
      charsPerToken: model.charsPerToken,
    );

    // Per-model multimodal payload estimation (Fix 2.2)
    final int imageTokens = req.imageCount * model.tokensPerImage;
    final int pdfTokens = req.pdfPageCount * model.tokensPerPdfPage;
    final int mediaTokens = req.mediaMinutes * model.tokensPerMediaMinute;
    final int multiTokens = imageTokens + pdfTokens + mediaTokens;

    final int initialPromptTokens = sysTokens + usrTokens + multiTokens;
    final int steps = req.mode == ExecutionMode.chat ? 1 : req.agentSteps;
    final int toolStepTokens =
        req.mode == ExecutionMode.chat ? 0 : req.toolPayloadTokensPerStep;
    final int outPerStep = req.visibleOutputTokensPerStep;
    final int thinkPerStep = req.reasoningEffort.tokenBudget;

    // Cacheable prefix includes System Prompt + static Multimodal attachments
    final int cacheablePrefixTokens = sysTokens + multiTokens;

    int totalUncachedInputTokens = 0;
    int totalCacheWriteTokens = 0;
    int totalCacheReadTokens = 0;
    int peakContextTokens = 0;
    bool crossedLongContext = false;

    double uncachedInputCost = 0.0;
    double cacheWriteCost = 0.0;
    double cacheReadCost = 0.0;
    double visibleOutputCost = 0.0;
    double reasoningOutputCost = 0.0;
    double uncachedBaselineCost = 0.0;
    double uncachedInputBaselineCost = 0.0;

    int rollingHistoryTokens = usrTokens;
    final List<TurnBreakdown> turnLog = [];

    for (int turn = 1; turn <= steps; turn++) {
      final int turnTotalContext = cacheablePrefixTokens + rollingHistoryTokens;
      if (turnTotalContext > peakContextTokens) {
        peakContextTokens = turnTotalContext;
      }

      // Only trigger tiered pricing if model actually has a distinct tier below max window (Fix 2.3)
      final bool isLongContextTurn =
          model.longContextThreshold < model.contextWindow &&
          turnTotalContext > model.longContextThreshold;
      if (isLongContextTurn) crossedLongContext = true;

      final double activeInRate = isLongContextTurn
          ? model.inputAboveThresholdPer1M
          : model.inputPer1M;
      final double activeOutRate = isLongContextTurn
          ? model.outputAboveThresholdPer1M
          : model.outputPer1M;
      final double activeReasonRate = isLongContextTurn
          ? math.max(
              model.reasoningOutputPer1M,
              model.outputAboveThresholdPer1M,
            )
          : model.reasoningOutputPer1M;

      // Baseline cost if caching were OFF
      final double turnUncachedInputBaseline =
          (turnTotalContext / 1000000.0) * activeInRate;
      final double turnOutCost = (outPerStep / 1000000.0) * activeOutRate;
      final double turnReasonCost =
          (thinkPerStep / 1000000.0) * activeReasonRate;

      uncachedInputBaselineCost += turnUncachedInputBaseline;
      uncachedBaselineCost +=
          turnUncachedInputBaseline + turnOutCost + turnReasonCost;

      int turnUncachedTok = 0;
      int turnCacheWriteTok = 0;
      int turnCacheReadTok = 0;
      double turnInputCost = 0.0;

      if (req.contextCachingEnabled &&
          req.mode == ExecutionMode.agent &&
          cacheablePrefixTokens > 0) {
        if (turn == 1) {
          // Turn 1 writes the static prefix to cache and bills dynamic user tokens normally (Fix 1.3)
          final double writeCost =
              (cacheablePrefixTokens / 1000000.0) * model.cacheWritePer1M;
          final double dynCost =
              (rollingHistoryTokens / 1000000.0) * activeInRate;
          cacheWriteCost += writeCost;
          uncachedInputCost += dynCost;
          turnInputCost = writeCost + dynCost;

          turnCacheWriteTok = cacheablePrefixTokens;
          turnUncachedTok = rollingHistoryTokens;
          totalCacheWriteTokens += cacheablePrefixTokens;
          totalUncachedInputTokens += rollingHistoryTokens;
        } else {
          // Turn 2..N reads the cached prefix at discounted rate + bills growing dynamic history
          final double readCost =
              (cacheablePrefixTokens / 1000000.0) * model.cacheReadPer1M;
          final double dynCost =
              (rollingHistoryTokens / 1000000.0) * activeInRate;
          cacheReadCost += readCost;
          uncachedInputCost += dynCost;
          turnInputCost = readCost + dynCost;

          turnCacheReadTok = cacheablePrefixTokens;
          turnUncachedTok = rollingHistoryTokens;
          totalCacheReadTokens += cacheablePrefixTokens;
          totalUncachedInputTokens += rollingHistoryTokens;
        }
      } else {
        // No context caching
        turnInputCost = turnUncachedInputBaseline;
        uncachedInputCost += turnInputCost;
        turnUncachedTok = turnTotalContext;
        totalUncachedInputTokens += turnTotalContext;
      }

      visibleOutputCost += turnOutCost;
      reasoningOutputCost += turnReasonCost;

      turnLog.add(
        TurnBreakdown(
          turnNumber: turn,
          totalContextTokens: turnTotalContext,
          uncachedInputTokens: turnUncachedTok,
          cacheWriteTokens: turnCacheWriteTok,
          cacheReadTokens: turnCacheReadTok,
          outputTokens: outPerStep,
          reasoningTokens: thinkPerStep,
          turnCost: turnInputCost + turnOutCost + turnReasonCost,
          isLongContextTier: isLongContextTurn,
        ),
      );

      // Compound context for the next agent step (prior output + tool observation)
      rollingHistoryTokens += outPerStep + toolStepTokens;
    }

    final double totalCostSingleRun = uncachedInputCost +
        cacheWriteCost +
        cacheReadCost +
        visibleOutputCost +
        reasoningOutputCost;

    return SimulationBreakdown(
      model: model,
      systemTextTokens: sysTokens,
      userTextTokens: usrTokens,
      multimodalTokens: multiTokens,
      initialPromptTokens: initialPromptTokens,
      peakTurnContextTokens: peakContextTokens,
      totalBilledInputTokens: totalUncachedInputTokens,
      totalCacheWriteTokens: totalCacheWriteTokens,
      totalCachedReadTokens: totalCacheReadTokens,
      totalVisibleOutputTokens: outPerStep * steps,
      totalReasoningTokens: thinkPerStep * steps,
      exceedsContextWindow: peakContextTokens > model.contextWindow,
      crossedLongContextTier: crossedLongContext,
      textWasTruncated: truncated,
      uncachedInputCost: uncachedInputCost,
      cacheWriteCost: cacheWriteCost,
      cacheReadCost: cacheReadCost,
      visibleOutputCost: visibleOutputCost,
      reasoningOutputCost: reasoningOutputCost,
      totalCostSingleRun: totalCostSingleRun,
      uncachedBaselineCost: uncachedBaselineCost,
      uncachedInputBaselineCost: uncachedInputBaselineCost,
      turns: turnLog,
    );
  }
}