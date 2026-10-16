import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TokenEstimatorApp());
}

// ============================================================================
// APP ROOT & THEME
// ============================================================================

class TokenEstimatorApp extends StatelessWidget {
  const TokenEstimatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Token & Agent Loop Cost Simulator',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF10B981),
          tertiary: Color(0xFFF59E0B),
          surface: Color(0xFF111827),
          onSurface: Color(0xFFF3F4F6),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111827),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF1F2937), width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0B0F19),
          contentPadding: const EdgeInsets.all(14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF374151)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF1F2937)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
          ),
        ),
      ),
      home: const EstimatorDashboard(),
    );
  }
}

// ============================================================================
// DATA MODELS & PRICING SCHEMA
// ============================================================================

enum ExecutionMode { chat, agent }

enum ReasoningEffort {
  off('Off', 0),
  low('Low (+1k)', 1024),
  medium('Med (+4k)', 4096),
  high('High (+16k)', 16384);

  final String label;
  final int tokenBudget;
  const ReasoningEffort(this.label, this.tokenBudget);
}

enum TokenKind { word, codePunct, number, whitespace }

class TokenSpanItem {
  final String text;
  final TokenKind kind;
  const TokenSpanItem(this.text, this.kind);
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
    );
  }
}

// Default curated frontier catalog with tiered thresholds & split cache pricing
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
  ),
];

// ============================================================================
// SIMULATION RESULT MODEL & ENGINE
// ============================================================================

class SimulationBreakdown {
  final ModelPricing model;
  final int systemTextTokens;
  final int userTextTokens;
  final int multimodalTokens;
  final int initialPromptTokens;
  final int peakTurnContextTokens;
  final int totalBilledInputTokens;
  final int totalCachedReadTokens;
  final int totalVisibleOutputTokens;
  final int totalReasoningTokens;
  final bool exceedsContextWindow;
  final bool crossedLongContextTier;

  final double uncachedInputCost;
  final double cacheWriteCost;
  final double cacheReadCost;
  final double visibleOutputCost;
  final double reasoningOutputCost;
  final double totalCostSingleRun;
  final double uncachedBaselineCost;

  const SimulationBreakdown({
    required this.model,
    required this.systemTextTokens,
    required this.userTextTokens,
    required this.multimodalTokens,
    required this.initialPromptTokens,
    required this.peakTurnContextTokens,
    required this.totalBilledInputTokens,
    required this.totalCachedReadTokens,
    required this.totalVisibleOutputTokens,
    required this.totalReasoningTokens,
    required this.exceedsContextWindow,
    required this.crossedLongContextTier,
    required this.uncachedInputCost,
    required this.cacheWriteCost,
    required this.cacheReadCost,
    required this.visibleOutputCost,
    required this.reasoningOutputCost,
    required this.totalCostSingleRun,
    required this.uncachedBaselineCost,
  });

  double get cacheSavingsPercent {
    if (uncachedBaselineCost <= 0) return 0;
    final diff = uncachedBaselineCost - totalCostSingleRun;
    return diff > 0 ? (diff / uncachedBaselineCost) * 100.0 : 0.0;
  }
}

class TokenizerEngine {
  static final RegExp _tokenRegex = RegExp(
    r'(\s+)|([0-9]+(?:\.[0-9]+)?)|([A-Za-z_][A-Za-z0-9_]*)|([^\sA-Za-z0-9_])',
  );

  /// Content-aware subword tokenizer that splits long identifiers and
  /// accounts for dense code punctuation vs. natural prose.
  static List<TokenSpanItem> tokenizeToSpans(
    String text, {
    double charsPerToken = 3.8,
  }) {
    if (text.isEmpty) return const [];
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
        // Words / identifiers: split long words into BPE-like subwords
        if (full.length <= subwordChunk + 2) {
          spans.add(TokenSpanItem(full, TokenKind.word));
        } else {
          for (int i = 0; i < full.length; i += subwordChunk) {
            spans.add(TokenSpanItem(
              full.substring(i, math.min(i + subwordChunk, full.length)),
              TokenKind.word,
            ));
          }
        }
      } else {
        // Code punctuation / symbols
        spans.add(TokenSpanItem(full, TokenKind.codePunct));
      }
    }
    return spans;
  }

  /// Counts non-whitespace merged subword tokens accurately.
  static int estimateTokenCount(String text, {double charsPerToken = 3.8}) {
    if (text.trim().isEmpty) return 0;
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
        count++;
        prevWasSpace = false;
      }
    }
    return math.max(1, count);
  }
}

// ============================================================================
// MAIN DASHBOARD SCREEN
// ============================================================================

class EstimatorDashboard extends StatefulWidget {
  const EstimatorDashboard({super.key});

  @override
  State<EstimatorDashboard> createState() => _EstimatorDashboardState();
}

class _EstimatorDashboardState extends State<EstimatorDashboard> {
  static const String _prefsCatalogKey = 'custom_pricing_catalog_v1';
  static const String _prefsLastSyncKey = 'last_pricing_sync_time_v1';

  List<ModelPricing> _catalog = List.from(kDefaultModelCatalog);
  late String _selectedModelId;

  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _userPromptCtrl;

  ExecutionMode _mode = ExecutionMode.agent;
  ReasoningEffort _reasoningEffort = ReasoningEffort.medium;

  // Agent Loop parameters
  int _agentSteps = 6;
  double _toolPayloadTokensPerStep = 1500;
  double _visibleOutputTokensPerStep = 450;
  bool _contextCachingEnabled = true;

  // Multimodal attachment counters
  int _imageCount = 1;
  int _pdfPageCount = 0;
  int _mediaMinutes = 0;

  // UI view toggles
  bool _showTokenInspector = false;
  int _batchMultiplier = 1; // 1, 1000, 100000
  bool _isSyncing = false;
  String? _lastSyncStatus;

  @override
  void initState() {
    super.initState();
    _selectedModelId = _catalog.first.id;
    _systemPromptCtrl = TextEditingController(
      text:
          'You are an autonomous Principal Systems & DevSecOps Agent.\n'
          'Analyze incoming repository telemetry, verify infrastructure constraints, '
          'and output deterministic JSON patch definitions without conversational filler.',
    );
    _userPromptCtrl = TextEditingController(
      text:
          'Refactor the telemetry WebSocket ingestion pipeline to batch incoming '
          'packets every 250ms, validate schema payloads, and log anomalies:\n\n'
          '```json\n'
          '{"service": "teleserver", "maxBatchSize": 128, "retryBackoffMs": [100, 250, 500]}\n'
          '```',
    );
    _systemPromptCtrl.addListener(_onInputChanged);
    _userPromptCtrl.addListener(_onInputChanged);
    _loadSavedPricingCatalog();
  }

  @override
  void dispose() {
    _systemPromptCtrl.dispose();
    _userPromptCtrl.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  ModelPricing get _activeModel => _catalog.firstWhere(
        (m) => m.id == _selectedModelId,
        orElse: () => _catalog.first,
      );

  // --------------------------------------------------------------------------
  // PERSISTENCE & LIVE OPENROUTER PRICING SYNC
  // --------------------------------------------------------------------------

  Future<void> _loadSavedPricingCatalog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString(_prefsCatalogKey);
      final savedTime = prefs.getString(_prefsLastSyncKey);
      if (savedJson != null && savedJson.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(savedJson) as List<dynamic>;
        final loaded = decoded
            .map((e) => ModelPricing.fromJson(e as Map<String, dynamic>))
            .toList();
        if (loaded.isNotEmpty && mounted) {
          setState(() {
            _catalog = loaded;
            if (!_catalog.any((m) => m.id == _selectedModelId)) {
              _selectedModelId = _catalog.first.id;
            }
            _lastSyncStatus = savedTime ?? 'Loaded custom local catalog';
          });
        }
      }
    } catch (_) {
      // Fallback silently to default catalog
    }
  }

  Future<void> _saveCatalogToPrefs(
    List<ModelPricing> updated,
    String statusLabel,
  ) async {
    setState(() {
      _catalog = updated;
      if (!_catalog.any((m) => m.id == _selectedModelId)) {
        _selectedModelId = _catalog.first.id;
      }
      _lastSyncStatus = statusLabel;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(updated.map((m) => m.toJson()).toList());
      await prefs.setString(_prefsCatalogKey, encoded);
      await prefs.setString(_prefsLastSyncKey, statusLabel);
    } catch (_) {}
  }

  Future<void> _syncLiveOpenRouterPricing() async {
    setState(() => _isSyncing = true);
    try {
      final uri = Uri.parse('https://openrouter.ai/api/v1/models');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final Map<String, dynamic> payload =
            jsonDecode(response.body) as Map<String, dynamic>;
        final List<dynamic> remoteModels =
            (payload['data'] as List<dynamic>?) ?? [];

        final Map<String, Map<String, dynamic>> byId = {};
        for (final item in remoteModels) {
          if (item is Map<String, dynamic> && item['id'] is String) {
            byId[item['id'] as String] = item;
          }
        }

        int matchedCount = 0;
        final List<ModelPricing> updatedCatalog = _catalog.map((localModel) {
          final slug = localModel.openRouterSlug;
          if (slug == null || !byId.containsKey(slug)) return localModel;

          final remote = byId[slug]!;
          final pricing = remote['pricing'] as Map<String, dynamic>?;
          if (pricing == null) return localModel;

          double? parsePer1M(dynamic val) {
            if (val == null) return null;
            final parsed = double.tryParse(val.toString());
            if (parsed == null || parsed <= 0) return null;
            return double.parse((parsed * 1000000.0).toStringAsFixed(4));
          }

          final liveIn = parsePer1M(pricing['prompt']);
          final liveOut = parsePer1M(pricing['completion']);
          final liveReason = parsePer1M(pricing['internal_reasoning']);
          final liveCacheWrite = parsePer1M(pricing['input_cache_write']);
          final liveCacheRead = parsePer1M(pricing['input_cache_read']);
          final liveContext = (remote['context_length'] as num?)?.toInt();

          if (liveIn != null && liveOut != null) {
            matchedCount++;
            return localModel.copyWith(
              contextWindow: liveContext ?? localModel.contextWindow,
              inputPer1M: liveIn,
              outputPer1M: liveOut,
              reasoningOutputPer1M: liveReason ?? liveOut,
              inputAboveThresholdPer1M: liveIn * 2.0,
              outputAboveThresholdPer1M: liveOut * 1.5,
              cacheWritePer1M: liveCacheWrite ?? liveIn,
              cacheReadPer1M: liveCacheRead ?? (liveIn * 0.25),
            );
          }
          return localModel;
        }).toList();

        final now = DateTime.now();
        final timestamp =
            'Live synced ($matchedCount models) at ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
        await _saveCatalogToPrefs(updatedCatalog, timestamp);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Synced live pricing from OpenRouter API ($matchedCount preset slugs matched).',
              ),
              backgroundColor: const Color(0xFF059669),
            ),
          );
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Live sync unreachable ($e). Using cached/local pricing catalog.',
            ),
            backgroundColor: const Color(0xFFD97706),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  // --------------------------------------------------------------------------
  // EXACT TURN-BY-TURN AGENT & CHAT SIMULATION ENGINE
  // --------------------------------------------------------------------------

  SimulationBreakdown _simulateForModel(ModelPricing model) {
    final int sysTokens = TokenizerEngine.estimateTokenCount(
      _systemPromptCtrl.text,
      charsPerToken: model.charsPerToken,
    );
    final int usrTokens = TokenizerEngine.estimateTokenCount(
      _userPromptCtrl.text,
      charsPerToken: model.charsPerToken,
    );

    // Multimodal payload estimation
    final int imageTokens = _imageCount * 258;
    final int pdfTokens = _pdfPageCount * 850;
    final int mediaTokens = _mediaMinutes * 15000; // ~250 tokens/sec
    final int multiTokens = imageTokens + pdfTokens + mediaTokens;

    final int initialPromptTokens = sysTokens + usrTokens + multiTokens;
    final int steps = _mode == ExecutionMode.chat ? 1 : _agentSteps;
    final int toolStepTokens =
        _mode == ExecutionMode.chat ? 0 : _toolPayloadTokensPerStep.round();
    final int outPerStep = _visibleOutputTokensPerStep.round();
    final int thinkPerStep = _reasoningEffort.tokenBudget;

    // Cacheable prefix includes System Prompt + static Multimodal attachments
    final int cacheablePrefixTokens = sysTokens + multiTokens;

    int totalUncachedInputTokens = 0;
    int totalCacheReadTokens = 0;
    int peakContextTokens = 0;
    bool crossedLongContext = false;

    double uncachedInputCost = 0.0;
    double cacheWriteCost = 0.0;
    double cacheReadCost = 0.0;
    double visibleOutputCost = 0.0;
    double reasoningOutputCost = 0.0;
    double uncachedBaselineCost = 0.0;

    int rollingHistoryTokens = usrTokens;

    for (int turn = 1; turn <= steps; turn++) {
      final int turnTotalContext = cacheablePrefixTokens + rollingHistoryTokens;
      if (turnTotalContext > peakContextTokens) {
        peakContextTokens = turnTotalContext;
      }

      final bool isLongContextTurn =
          turnTotalContext > model.longContextThreshold;
      if (isLongContextTurn) crossedLongContext = true;

      final double activeInRate = isLongContextTurn
          ? model.inputAboveThresholdPer1M
          : model.inputPer1M;
      final double activeOutRate = isLongContextTurn
          ? model.outputAboveThresholdPer1M
          : model.outputPer1M;
      final double activeReasonRate = isLongContextTurn
          ? math.max(model.reasoningOutputPer1M, model.outputAboveThresholdPer1M)
          : model.reasoningOutputPer1M;

      // Baseline cost if caching were OFF
      uncachedBaselineCost +=
          (turnTotalContext / 1000000.0) * activeInRate +
          (outPerStep / 1000000.0) * activeOutRate +
          (thinkPerStep / 1000000.0) * activeReasonRate;

      if (_contextCachingEnabled &&
          _mode == ExecutionMode.agent &&
          cacheablePrefixTokens > 0) {
        if (turn == 1) {
          // Turn 1 writes the static prefix to cache and bills dynamic user tokens normally
          cacheWriteCost +=
              (cacheablePrefixTokens / 1000000.0) * model.cacheWritePer1M;
          uncachedInputCost += (rollingHistoryTokens / 1000000.0) * activeInRate;
          totalUncachedInputTokens +=
              cacheablePrefixTokens + rollingHistoryTokens;
        } else {
          // Turn 2..N reads the cached prefix at discounted rate + bills growing dynamic history
          cacheReadCost +=
              (cacheablePrefixTokens / 1000000.0) * model.cacheReadPer1M;
          uncachedInputCost += (rollingHistoryTokens / 1000000.0) * activeInRate;
          totalCacheReadTokens += cacheablePrefixTokens;
          totalUncachedInputTokens += rollingHistoryTokens;
        }
      } else {
        // No context caching
        uncachedInputCost += (turnTotalContext / 1000000.0) * activeInRate;
        totalUncachedInputTokens += turnTotalContext;
      }

      visibleOutputCost += (outPerStep / 1000000.0) * activeOutRate;
      reasoningOutputCost += (thinkPerStep / 1000000.0) * activeReasonRate;

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
      totalCachedReadTokens: totalCacheReadTokens,
      totalVisibleOutputTokens: outPerStep * steps,
      totalReasoningTokens: thinkPerStep * steps,
      exceedsContextWindow: peakContextTokens > model.contextWindow,
      crossedLongContextTier: crossedLongContext,
      uncachedInputCost: uncachedInputCost,
      cacheWriteCost: cacheWriteCost,
      cacheReadCost: cacheReadCost,
      visibleOutputCost: visibleOutputCost,
      reasoningOutputCost: reasoningOutputCost,
      totalCostSingleRun: totalCostSingleRun,
      uncachedBaselineCost: uncachedBaselineCost,
    );
  }

  // --------------------------------------------------------------------------
  // PRICING SCHEMA & JSON OVERRIDE MODAL
  // --------------------------------------------------------------------------

  void _openPricingSchemaModal() {
    final jsonController = TextEditingController(
      text: const JsonEncoder.withIndent('  ')
          .convert(_catalog.map((m) => m.toJson()).toList()),
    );
    String? errorText;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF111827),
              title: const Row(
                children: [
                  Icon(Icons.schema_outlined, color: Color(0xFF6366F1)),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Pricing Schema & JSON Override Editor',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 720,
                height: 480,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Edit per-1M token rates, long-context thresholds (e.g. 200000), and Turn-1 Cache Write vs. Turn-N Cache Read rates. Changes persist locally via SharedPreferences.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                    ),
                    const SizedBox(height: 12),
                    if (errorText != null)
                      Container(
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7F1D1D),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          errorText!,
                          style: const TextStyle(
                            color: Color(0xFFFCA5A5),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Expanded(
                      child: TextField(
                        controller: jsonController,
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          color: Color(0xFFE5E7EB),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton.icon(
                  onPressed: () async {
                    await _saveCatalogToPrefs(
                      List.from(kDefaultModelCatalog),
                      'Reset to factory defaults',
                    );
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                  icon: const Icon(Icons.restore, size: 18),
                  label: const Text('Reset Defaults'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    try {
                      final decoded =
                          jsonDecode(jsonController.text) as List<dynamic>;
                      final parsed = decoded
                          .map((e) =>
                              ModelPricing.fromJson(e as Map<String, dynamic>))
                          .toList();
                      if (parsed.isEmpty) {
                        throw const FormatException(
                            'Model catalog cannot be empty.');
                      }
                      await _saveCatalogToPrefs(
                        parsed,
                        'Saved custom JSON overrides',
                      );
                      if (ctx.mounted) Navigator.of(ctx).pop();
                    } catch (e) {
                      setModalState(() {
                        errorText = 'Invalid JSON Schema: $e';
                      });
                    }
                  },
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save & Persist Schema'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // UI BUILDERS
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final activeSim = _simulateForModel(_activeModel);
    final allSimulations = _catalog.map(_simulateForModel).toList();

    return Scaffold(
      appBar: _buildAppBar(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool isWide = constraints.maxWidth >= 960;
          if (isWide) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 7,
                            child: _buildLeftConfigurationColumn(activeSim),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            flex: 5,
                            child: _buildRightTelemetryColumn(activeSim),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      _buildComparisonMatrixCard(allSimulations),
                    ],
                  ),
                ),
              ),
            );
          } else {
            // Compact layout for Mobile or Narrow Desktop/Web Windows
            return Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildLeftConfigurationColumn(activeSim),
                        const SizedBox(height: 16),
                        _buildRightTelemetryColumn(activeSim),
                        const SizedBox(height: 16),
                        _buildComparisonMatrixCard(allSimulations),
                      ],
                    ),
                  ),
                ),
                _buildMobilePinnedSummaryBar(activeSim),
              ],
            );
          }
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF111827),
      surfaceTintColor: Colors.transparent,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1).withAlpha(35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF6366F1).withAlpha(90)),
            ),
            child: const Icon(
              Icons.calculate_outlined,
              color: Color(0xFF818CF8),
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'AI Token & Agent Loop Cost Simulator',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _lastSyncStatus ??
                      'Tiered Context + Split Cache Write/Read Engine',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF9CA3AF),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _isSyncing ? null : _syncLiveOpenRouterPricing,
            icon: _isSyncing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync, size: 16),
            label: const Text('Sync Live Rates'),
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(right: 14, top: 8, bottom: 8),
          child: FilledButton.tonalIcon(
            onPressed: _openPricingSchemaModal,
            icon: const Icon(Icons.tune, size: 16),
            label: const Text('Schema / JSON'),
          ),
        ),
      ],
    );
  }

  Widget _buildLeftConfigurationColumn(SimulationBreakdown sim) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildModeAndModelSelectorCard(),
        const SizedBox(height: 16),
        _buildSplitPromptInputsCard(sim),
        const SizedBox(height: 16),
        _buildAgentAndReasoningControlsCard(),
        const SizedBox(height: 16),
        _buildMultimodalAttachmentsCard(sim),
      ],
    );
  }

  Widget _buildModeAndModelSelectorCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 14,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // Mode Segmented Control
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'EXECUTION ARCHITECTURE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<ExecutionMode>(
                  segments: const [
                    ButtonSegment(
                      value: ExecutionMode.chat,
                      icon: Icon(Icons.chat_bubble_outline, size: 16),
                      label: Text('Chat (1-Turn)'),
                    ),
                    ButtonSegment(
                      value: ExecutionMode.agent,
                      icon: Icon(Icons.account_tree_outlined, size: 16),
                      label: Text('Task / Agent Loop'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (val) {
                    setState(() => _mode = val.first);
                  },
                ),
              ],
            ),

            // Target Model Dropdown
             ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 270, maxWidth: 360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'PRIMARY TARGET MODEL',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedModelId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: _catalog.map((m) {
                      return DropdownMenuItem<String>(
                        value: m.id,
                        child: Text(
                          '${m.name} (\$${m.inputPer1M.toStringAsFixed(2)} / \$${m.outputPer1M.toStringAsFixed(2)})',
                          style: const TextStyle(fontSize: 13.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedModelId = val);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitPromptInputsCard(SimulationBreakdown sim) {
    final combinedText =
        '${_systemPromptCtrl.text}\n${_userPromptCtrl.text}'.trim();
    final spans = _showTokenInspector
        ? TokenizerEngine.tokenizeToSpans(
            combinedText,
            charsPerToken: _activeModel.charsPerToken,
          )
        : const <TokenSpanItem>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.splitscreen, size: 18, color: Color(0xFF818CF8)),
                    SizedBox(width: 8),
                    Text(
                      'Split-Pane Prompt Context',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text(
                        'Inspect Subword Tokens',
                        style: TextStyle(fontSize: 12),
                      ),
                      selected: _showTokenInspector,
                      onSelected: (v) =>
                          setState(() => _showTokenInspector = v),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        _systemPromptCtrl.clear();
                        _userPromptCtrl.clear();
                      },
                      icon: const Icon(Icons.delete_outline, size: 16),
                      label: const Text('Clear', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),

            // System Prompt Pane
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '1. System Instructions / Cached Prefix (Static Across Loop)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF10B981),
                  ),
                ),
                Text(
                  '${sim.systemTextTokens} tokens',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Color(0xFF10B981),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _systemPromptCtrl,
              minLines: 3,
              maxLines: 5,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
              decoration: const InputDecoration(
                hintText:
                    'Paste system prompt, tool definitions, or few-shot examples eligible for prefix caching...',
              ),
            ),
            const SizedBox(height: 14),

            // Dynamic User Prompt Pane
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '2. Dynamic User Prompt / Initial RAG Payload',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF818CF8),
                  ),
                ),
                Text(
                  '${sim.userTextTokens} tokens • ${combinedText.length} chars',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _userPromptCtrl,
              minLines: 4,
              maxLines: 8,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
              decoration: const InputDecoration(
                hintText:
                    'Paste user query, code files, or dynamic RAG context...',
              ),
            ),

            // Optional Visual Subword Token Inspector
            if (_showTokenInspector) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0F19),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF1F2937)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        _LegendBadge(
                          color: Color(0xFF312E81),
                          label: 'Word / Subword',
                        ),
                        _LegendBadge(
                          color: Color(0xFF78350F),
                          label: 'Code / Punctuation',
                        ),
                        _LegendBadge(
                          color: Color(0xFF064E3B),
                          label: 'Numeric Literal',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 190),
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: spans
                              .where((s) => s.kind != TokenKind.whitespace)
                              .take(400)
                              .map((span) {
                            Color bg;
                            switch (span.kind) {
                              case TokenKind.word:
                                bg = const Color(0xFF312E81);
                              case TokenKind.codePunct:
                                bg = const Color(0xFF78350F);
                              case TokenKind.number:
                                bg = const Color(0xFF064E3B);
                              case TokenKind.whitespace:
                                bg = const Color(0xFF1F2937);
                            }
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: bg,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                span.text,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAgentAndReasoningControlsCard() {
    final isAgent = _mode == ExecutionMode.agent;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.auto_graph, size: 18, color: Color(0xFFF59E0B)),
                    SizedBox(width: 8),
                    Text(
                      'Compounding Agent Loop & Reasoning Controls',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (isAgent)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Context Caching',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF10B981),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Switch(
                        value: _contextCachingEnabled,
                        onChanged: (v) =>
                            setState(() => _contextCachingEnabled = v),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Reasoning Effort Segmented Control
            const Text(
              'INTERNAL THINKING / REASONING EFFORT (BILLED AT OUTPUT RATE PER STEP)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9CA3AF),
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ReasoningEffort>(
              segments: ReasoningEffort.values.map((effort) {
                return ButtonSegment<ReasoningEffort>(
                  value: effort,
                  label: Text(
                    effort.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              }).toList(),
              selected: {_reasoningEffort},
              onSelectionChanged: (val) {
                setState(() => _reasoningEffort = val.first);
              },
            ),
            const SizedBox(height: 16),

            if (isAgent) ...[
              _buildSliderRow(
                label: 'Autonomous Agent / Tool Steps',
                valueText: '$_agentSteps turns',
                value: _agentSteps.toDouble(),
                min: 1,
                max: 25,
                divisions: 24,
                onChanged: (v) => setState(() => _agentSteps = v.round()),
              ),
              _buildSliderRow(
                label: 'Avg Tool Observation Payload Added per Step',
                valueText: '${_toolPayloadTokensPerStep.round()} tokens/step',
                value: _toolPayloadTokensPerStep,
                min: 0,
                max: 10000,
                divisions: 40,
                onChanged: (v) => setState(() => _toolPayloadTokensPerStep = v),
              ),
            ],

            _buildSliderRow(
              label: isAgent
                  ? 'Visible Model Output per Step'
                  : 'Expected Visible Completion Output',
              valueText: '${_visibleOutputTokensPerStep.round()} tokens',
              value: _visibleOutputTokensPerStep,
              min: 100,
              max: 8000,
              divisions: 79,
              onChanged: (v) =>
                  setState(() => _visibleOutputTokensPerStep = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 13)),
              Text(
                valueText,
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF818CF8),
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildMultimodalAttachmentsCard(SimulationBreakdown sim) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.perm_media_outlined,
                      size: 18,
                      color: Color(0xFF10B981),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Multimodal Payload Attachments',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  '+${_formatNumber(sim.multimodalTokens)} tokens',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: Color(0xFF10B981),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 12,
              children: [
                _buildCounterBox(
                  title: 'Images',
                  subtitle: '~258 tok / img',
                  count: _imageCount,
                  onChanged: (v) => setState(() => _imageCount = v),
                ),
                _buildCounterBox(
                  title: 'PDF Pages',
                  subtitle: '~850 tok / page',
                  count: _pdfPageCount,
                  onChanged: (v) => setState(() => _pdfPageCount = v),
                ),
                _buildCounterBox(
                  title: 'Video / Audio',
                  subtitle: '~15k tok / min',
                  count: _mediaMinutes,
                  onChanged: (v) => setState(() => _mediaMinutes = v),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCounterBox({
    required String title,
    required String subtitle,
    required int count,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      width: 210,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F19),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: count > 0 ? () => onChanged(count - 1) : null,
                icon: const Icon(Icons.remove_circle_outline, size: 18),
              ),
              Text(
                '$count',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => onChanged(count + 1),
                icon: const Icon(Icons.add_circle_outline, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // RIGHT TELEMETRY & COST BREAKDOWN COLUMN
  // --------------------------------------------------------------------------

  Widget _buildRightTelemetryColumn(SimulationBreakdown sim) {
    final scaledCost = sim.totalCostSingleRun * _batchMultiplier;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  sim.model.name.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                    color: Color(0xFF818CF8),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: sim.exceedsContextWindow
                        ? const Color(0xFF7F1D1D)
                        : const Color(0xFF064E3B),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    sim.exceedsContextWindow
                        ? 'OVERFLOW (> ${_formatNumber(sim.model.contextWindow)})'
                        : 'Peak Context: ${_formatNumber(sim.peakTurnContextTokens)} / ${_formatNumber(sim.model.contextWindow)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: sim.exceedsContextWindow
                          ? const Color(0xFFFCA5A5)
                          : const Color(0xFF6EE7B7),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Hero Cost Display
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E1B4B), Color(0xFF0F172A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF312E81)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _batchMultiplier == 1
                            ? 'ESTIMATED SINGLE WORKFLOW COST'
                            : 'ESTIMATED COST (${_formatNumber(_batchMultiplier)} RUNS)',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFA5B4FC),
                        ),
                      ),
                      if (sim.cacheSavingsPercent > 0.5)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF065F46),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            'Cache Saved ${sim.cacheSavingsPercent.toStringAsFixed(1)}%',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF6EE7B7),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatCurrency(scaledCost),
                    style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                      color: Colors.white,
                    ),
                  ),
                  if (sim.crossedLongContextTier)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 15,
                            color: Color(0xFFFBBF24),
                          ),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Crossed Long-Context Threshold: Tiered premium rates applied on later steps.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFFFBBF24),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Batch Scale Selector
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Batch Projection Scale:',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF9CA3AF)),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('1 Run')),
                    ButtonSegment(value: 1000, label: Text('1k Runs')),
                    ButtonSegment(value: 100000, label: Text('100k Runs')),
                  ],
                  selected: {_batchMultiplier},
                  onSelectionChanged: (v) =>
                      setState(() => _batchMultiplier = v.first),
                ),
              ],
            ),
            const Divider(height: 28, color: Color(0xFF1F2937)),

            // Granular Token & Cost Ledger
            const Text(
              'GRANULAR TOKEN & BILLING LEDGER (PER 1 WORKFLOW)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9CA3AF),
              ),
            ),
            const SizedBox(height: 12),
            _buildLedgerRow(
              label: 'Uncached Input / Compounding History',
              tokens: '${_formatNumber(sim.totalBilledInputTokens)} tok',
              cost: _formatCurrency(sim.uncachedInputCost),
            ),
            _buildLedgerRow(
              label: 'Turn-1 Cache Write + Turn-N Cache Reads',
              tokens: '${_formatNumber(sim.totalCachedReadTokens)} read tok',
              cost: _formatCurrency(sim.cacheWriteCost + sim.cacheReadCost),
              highlightColor: const Color(0xFF10B981),
            ),
            _buildLedgerRow(
              label: 'Visible Model Output Tokens',
              tokens: '${_formatNumber(sim.totalVisibleOutputTokens)} tok',
              cost: _formatCurrency(sim.visibleOutputCost),
            ),
            _buildLedgerRow(
              label: 'Hidden Internal Thinking / Reasoning',
              tokens: '${_formatNumber(sim.totalReasoningTokens)} tok',
              cost: _formatCurrency(sim.reasoningOutputCost),
              highlightColor: const Color(0xFFF59E0B),
            ),
            const Divider(height: 24, color: Color(0xFF1F2937)),

            // Active Model Rate Card Summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F19),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF1F2937)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Active Schema Rates (${sim.model.name} • per 1M tokens)',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '• Base In/Out: \$${sim.model.inputPer1M.toStringAsFixed(2)} / \$${sim.model.outputPer1M.toStringAsFixed(2)}  |  '
                    '>${_formatNumber(sim.model.longContextThreshold)} Tier: \$${sim.model.inputAboveThresholdPer1M.toStringAsFixed(2)} / \$${sim.model.outputAboveThresholdPer1M.toStringAsFixed(2)}\n'
                    '• Cache Write (Turn 1): \$${sim.model.cacheWritePer1M.toStringAsFixed(2)}  |  '
                    'Cache Read (Turn 2..N): \$${sim.model.cacheReadPer1M.toStringAsFixed(3)}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      fontFamily: 'monospace',
                      color: Color(0xFFD1D5DB),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                final summary =
                    'Model: ${sim.model.name} (${_mode.name.toUpperCase()})\n'
                    'Peak Turn Context: ${_formatNumber(sim.peakTurnContextTokens)} tokens\n'
                    'Billed Uncached Input: ${_formatNumber(sim.totalBilledInputTokens)} tokens\n'
                    'Cached Read Hits: ${_formatNumber(sim.totalCachedReadTokens)} tokens\n'
                    'Output + Thinking: ${_formatNumber(sim.totalVisibleOutputTokens + sim.totalReasoningTokens)} tokens\n'
                    'Cost (1 Run): ${_formatCurrency(sim.totalCostSingleRun)}\n'
                    'Cost (${_formatNumber(_batchMultiplier)} Runs): ${_formatCurrency(scaledCost)}';
                Clipboard.setData(ClipboardData(text: summary));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied cost telemetry report to clipboard.'),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy Telemetry Report'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLedgerRow({
    required String label,
    required String tokens,
    required String cost,
    Color? highlightColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: highlightColor ?? const Color(0xFFD1D5DB),
              ),
            ),
          ),
          Text(
            tokens,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: Color(0xFF9CA3AF),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 86,
            child: Text(
              cost,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                color: highlightColor ?? Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // SIDE-BY-SIDE FRONTIER COMPARISON MATRIX
  // --------------------------------------------------------------------------

  Widget _buildComparisonMatrixCard(List<SimulationBreakdown> simulations) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.table_chart_outlined,
                      size: 18,
                      color: Color(0xFF818CF8),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Side-by-Side Frontier Model Comparison Matrix',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Scaled by ${_formatNumber(_batchMultiplier)}x',
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: Color(0xFF10B981),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                  const Color(0xFF0B0F19),
                ),
                columns: const [
                  DataColumn(label: Text('Model')),
                  DataColumn(label: Text('Base In / Out (1M)')),
                  DataColumn(label: Text('Cache Write / Read')),
                  DataColumn(label: Text('Peak Context')),
                  DataColumn(label: Text('1-Run Cost')),
                  DataColumn(label: Text('Scaled Batch Cost')),
                  DataColumn(label: Text('Cache Savings')),
                ],
                rows: simulations.map((sim) {
                  final isSelected = sim.model.id == _selectedModelId;
                  return DataRow(
                    selected: isSelected,
                    onSelectChanged: (_) {
                      setState(() => _selectedModelId = sim.model.id);
                    },
                    cells: [
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              sim.model.name,
                              style: TextStyle(
                                fontWeight: isSelected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: isSelected
                                    ? const Color(0xFF818CF8)
                                    : Colors.white,
                              ),
                            ),
                            if (sim.exceedsContextWindow)
                              const Padding(
                                padding: EdgeInsets.only(left: 6),
                                child: Tooltip(
                                  message: 'Exceeds model max context window',
                                  child: Icon(
                                    Icons.error_outline,
                                    color: Color(0xFFEF4444),
                                    size: 16,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          '\$${sim.model.inputPer1M.toStringAsFixed(2)} / \$${sim.model.outputPer1M.toStringAsFixed(2)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      DataCell(
                        Text(
                          '\$${sim.model.cacheWritePer1M.toStringAsFixed(2)} / \$${sim.model.cacheReadPer1M.toStringAsFixed(3)}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      DataCell(
                        Text(
                          '${_formatNumber(sim.peakTurnContextTokens)} tok',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      DataCell(
                        Text(
                          _formatCurrency(sim.totalCostSingleRun),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          _formatCurrency(
                            sim.totalCostSingleRun * _batchMultiplier,
                          ),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF10B981),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          sim.cacheSavingsPercent > 0.5
                              ? '-${sim.cacheSavingsPercent.toStringAsFixed(1)}%'
                              : '0%',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            color: sim.cacheSavingsPercent > 0.5
                                ? const Color(0xFF34D399)
                                : const Color(0xFF6B7280),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobilePinnedSummaryBar(SimulationBreakdown sim) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF111827),
        border: Border(top: BorderSide(color: Color(0xFF1F2937))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${sim.model.name} (${_mode.name.toUpperCase()})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF818CF8),
                  ),
                ),
                Text(
                  'Peak: ${_formatNumber(sim.peakTurnContextTokens)} tok',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF9CA3AF),
                  ),
                ),
              ],
            ),
            Text(
              _formatCurrency(sim.totalCostSingleRun * _batchMultiplier),
              style: const TextStyle(
                fontSize: 20,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                color: Color(0xFF10B981),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // FORMATTING HELPERS
  // --------------------------------------------------------------------------

  String _formatNumber(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _formatCurrency(double val) {
    if (val == 0) return '\$0.0000';
    if (val < 0.01) return '\$${val.toStringAsFixed(5)}';
    if (val < 1.0) return '\$${val.toStringAsFixed(4)}';
    return '\$${val.toStringAsFixed(2)}';
  }
}

class _LegendBadge extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendBadge({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF)),
        ),
      ],
    );
  }
}