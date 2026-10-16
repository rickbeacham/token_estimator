// ============================================================================
// DATA MODELS & PRICING SCHEMA
// ============================================================================

enum ExecutionMode { chat, agent }

class ReasoningPreset {
  final String id;
  final String label;
  final String shortLabel;
  final int tokenBudget;

  const ReasoningPreset({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.tokenBudget,
  });

  static const off = ReasoningPreset(
    id: 'off',
    label: 'Off',
    shortLabel: 'Off',
    tokenBudget: 0,
  );
  static const low = ReasoningPreset(
    id: 'low',
    label: 'Low (+1k)',
    shortLabel: '+1k',
    tokenBudget: 1024,
  );
  static const medium = ReasoningPreset(
    id: 'med',
    label: 'Med (+4k)',
    shortLabel: '+4k',
    tokenBudget: 4096,
  );
  static const high = ReasoningPreset(
    id: 'high',
    label: 'High (+16k)',
    shortLabel: '+16k',
    tokenBudget: 16384,
  );

  static const List<ReasoningPreset> values = [off, low, medium, high];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReasoningPreset && other.id == id);

  @override
  int get hashCode => id.hashCode;
}

class ModelPricing {
  final String id;
  final String name;
  final String provider;
  final String? openRouterSlug;
  final int contextWindow;
  final double charsPerToken;

  // Base pricing per 1M tokens (USD)
  final double inputPer1M;
  final double outputPer1M;
  final double reasoningOutputPer1M;

  // Tiered context threshold pricing (e.g. >128k or >200k tokens)
  final int longContextThreshold;
  final double inputAboveThresholdPer1M;
  final double outputAboveThresholdPer1M;

  // Split Context Cache pricing per 1M tokens (USD)
  final double cacheWritePer1M; // Turn 1 creation rate
  final double cacheReadPer1M; // Turn 2..N read hit rate

  // Model-specific multimodal token weights
  final int tokensPerImage;
  final int tokensPerPdfPage;
  final int tokensPerMediaMinute;

  const ModelPricing({
    required this.id,
    required this.name,
    required this.provider,
    this.openRouterSlug,
    required this.contextWindow,
    required this.charsPerToken,
    required this.inputPer1M,
    required this.outputPer1M,
    required this.reasoningOutputPer1M,
    required this.longContextThreshold,
    required this.inputAboveThresholdPer1M,
    required this.outputAboveThresholdPer1M,
    required this.cacheWritePer1M,
    required this.cacheReadPer1M,
    this.tokensPerImage = 258,
    this.tokensPerPdfPage = 850,
    this.tokensPerMediaMinute = 15000,
  });

  ModelPricing copyWith({
    String? name,
    String? provider,
    int? contextWindow,
    double? charsPerToken,
    double? inputPer1M,
    double? outputPer1M,
    double? reasoningOutputPer1M,
    int? longContextThreshold,
    double? inputAboveThresholdPer1M,
    double? outputAboveThresholdPer1M,
    double? cacheWritePer1M,
    double? cacheReadPer1M,
    int? tokensPerImage,
    int? tokensPerPdfPage,
    int? tokensPerMediaMinute,
  }) {
    return ModelPricing(
      id: id,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      openRouterSlug: openRouterSlug,
      contextWindow: contextWindow ?? this.contextWindow,
      charsPerToken: charsPerToken ?? this.charsPerToken,
      inputPer1M: inputPer1M ?? this.inputPer1M,
      outputPer1M: outputPer1M ?? this.outputPer1M,
      reasoningOutputPer1M: reasoningOutputPer1M ?? this.reasoningOutputPer1M,
      longContextThreshold: longContextThreshold ?? this.longContextThreshold,
      inputAboveThresholdPer1M:
          inputAboveThresholdPer1M ?? this.inputAboveThresholdPer1M,
      outputAboveThresholdPer1M:
          outputAboveThresholdPer1M ?? this.outputAboveThresholdPer1M,
      cacheWritePer1M: cacheWritePer1M ?? this.cacheWritePer1M,
      cacheReadPer1M: cacheReadPer1M ?? this.cacheReadPer1M,
      tokensPerImage: tokensPerImage ?? this.tokensPerImage,
      tokensPerPdfPage: tokensPerPdfPage ?? this.tokensPerPdfPage,
      tokensPerMediaMinute: tokensPerMediaMinute ?? this.tokensPerMediaMinute,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'openRouterSlug': openRouterSlug,
        'contextWindow': contextWindow,
        'charsPerToken': charsPerToken,
        'inputPer1M': inputPer1M,
        'outputPer1M': outputPer1M,
        'reasoningOutputPer1M': reasoningOutputPer1M,
        'longContextThreshold': longContextThreshold,
        'inputAboveThresholdPer1M': inputAboveThresholdPer1M,
        'outputAboveThresholdPer1M': outputAboveThresholdPer1M,
        'cacheWritePer1M': cacheWritePer1M,
        'cacheReadPer1M': cacheReadPer1M,
        'tokensPerImage': tokensPerImage,
        'tokensPerPdfPage': tokensPerPdfPage,
        'tokensPerMediaMinute': tokensPerMediaMinute,
      };

  factory ModelPricing.fromJson(Map<String, dynamic> json) {
    final double inBase = (json['inputPer1M'] as num?)?.toDouble() ?? 2.0;
    final double outBase = (json['outputPer1M'] as num?)?.toDouble() ?? 8.0;
    return ModelPricing(
      id: json['id'] as String? ?? 'custom',
      name: json['name'] as String? ?? 'Custom Model',
      provider: json['provider'] as String? ?? 'Custom',
      openRouterSlug: json['openRouterSlug'] as String?,
      contextWindow: (json['contextWindow'] as num?)?.toInt() ?? 128000,
      charsPerToken: (json['charsPerToken'] as num?)?.toDouble() ?? 3.8,
      inputPer1M: inBase,
      outputPer1M: outBase,
      reasoningOutputPer1M:
          (json['reasoningOutputPer1M'] as num?)?.toDouble() ?? outBase,
      longContextThreshold:
          (json['longContextThreshold'] as num?)?.toInt() ?? 200000,
      inputAboveThresholdPer1M:
          (json['inputAboveThresholdPer1M'] as num?)?.toDouble() ?? inBase * 2,
      outputAboveThresholdPer1M:
          (json['outputAboveThresholdPer1M'] as num?)?.toDouble() ??
              outBase * 2,
      cacheWritePer1M:
          (json['cacheWritePer1M'] as num?)?.toDouble() ?? inBase * 1.25,
      cacheReadPer1M:
          (json['cacheReadPer1M'] as num?)?.toDouble() ?? inBase * 0.25,
      tokensPerImage: (json['tokensPerImage'] as num?)?.toInt() ?? 258,
      tokensPerPdfPage: (json['tokensPerPdfPage'] as num?)?.toInt() ?? 850,
      tokensPerMediaMinute:
          (json['tokensPerMediaMinute'] as num?)?.toInt() ?? 15000,
    );
  }
}

// Default curated frontier catalog with per-model multimodal token weights
const List<ModelPricing> kDefaultModelCatalog = [
  ModelPricing(
    id: 'gemini-4-argon',
    name: 'Gemini 4 Argon',
    provider: 'Google',
    openRouterSlug: 'google/gemini-2.5-pro',
    contextWindow: 1000000,
    charsPerToken: 3.85,
    inputPer1M: 1.25,
    outputPer1M: 10.00,
    reasoningOutputPer1M: 10.00,
    longContextThreshold: 200000,
    inputAboveThresholdPer1M: 2.50,
    outputAboveThresholdPer1M: 15.00,
    cacheWritePer1M: 1.25,
    cacheReadPer1M: 0.31,
    tokensPerImage: 258,
    tokensPerPdfPage: 850,
    tokensPerMediaMinute: 15000,
  ),
  ModelPricing(
    id: 'gemini-3-flash',
    name: 'Gemini 3.x Flash',
    provider: 'Google',
    openRouterSlug: 'google/gemini-2.5-flash',
    contextWindow: 1000000,
    charsPerToken: 3.85,
    inputPer1M: 0.15,
    outputPer1M: 0.60,
    reasoningOutputPer1M: 0.60,
    longContextThreshold: 200000,
    inputAboveThresholdPer1M: 0.30,
    outputAboveThresholdPer1M: 1.20,
    cacheWritePer1M: 0.15,
    cacheReadPer1M: 0.0375,
    tokensPerImage: 258,
    tokensPerPdfPage: 850,
    tokensPerMediaMinute: 15000,
  ),
  ModelPricing(
    id: 'claude-sonnet',
    name: 'Claude Sonnet (Frontier)',
    provider: 'Anthropic',
    openRouterSlug: 'anthropic/claude-3.7-sonnet',
    contextWindow: 200000,
    charsPerToken: 3.70,
    inputPer1M: 3.00,
    outputPer1M: 15.00,
    reasoningOutputPer1M: 15.00,
    longContextThreshold: 200000,
    inputAboveThresholdPer1M: 6.00,
    outputAboveThresholdPer1M: 22.50,
    cacheWritePer1M: 3.75, // +25% cache write penalty on Turn 1
    cacheReadPer1M: 0.30, // 90% discount on cache read
    tokensPerImage: 1600,
    tokensPerPdfPage: 1500,
    tokensPerMediaMinute: 18000,
  ),
  ModelPricing(
    id: 'gpt-4o',
    name: 'GPT-4o / Frontier',
    provider: 'OpenAI',
    openRouterSlug: 'openai/gpt-4o',
    contextWindow: 128000,
    charsPerToken: 3.75,
    inputPer1M: 2.50,
    outputPer1M: 10.00,
    reasoningOutputPer1M: 10.00,
    longContextThreshold: 128000,
    inputAboveThresholdPer1M: 5.00,
    outputAboveThresholdPer1M: 20.00,
    cacheWritePer1M: 2.50,
    cacheReadPer1M: 1.25, // 50% discount on cached prefix
    tokensPerImage: 765,
    tokensPerPdfPage: 1100,
    tokensPerMediaMinute: 12000,
  ),
  ModelPricing(
    id: 'open-weights-70b',
    name: 'Llama / DeepSeek (Open Weights)',
    provider: 'Open / Cloud',
    openRouterSlug: 'deepseek/deepseek-chat',
    contextWindow: 128000,
    charsPerToken: 3.65,
    inputPer1M: 0.27,
    outputPer1M: 1.10,
    reasoningOutputPer1M: 1.10,
    longContextThreshold: 128000,
    inputAboveThresholdPer1M: 0.54,
    outputAboveThresholdPer1M: 2.20,
    cacheWritePer1M: 0.27,
    cacheReadPer1M: 0.07,
    tokensPerImage: 512,
    tokensPerPdfPage: 900,
    tokensPerMediaMinute: 15000,
  ),
];