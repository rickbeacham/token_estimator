import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/catalog_repository.dart';
import '../engine/simulator.dart';
import '../engine/tokenizer.dart';
import '../pricing/model_pricing.dart';
import 'widgets/legend_badge.dart';
import 'widgets/pricing_schema_dialog.dart';

// ============================================================================
// MAIN DASHBOARD SCREEN
// ============================================================================

class EstimatorDashboard extends StatefulWidget {
  const EstimatorDashboard({super.key});

  @override
  State<EstimatorDashboard> createState() => _EstimatorDashboardState();
}

class _EstimatorDashboardState extends State<EstimatorDashboard> {
  static const SimulationEngine _simulationEngine = SimulationEngine();
  final CatalogRepository _catalogRepo = CatalogRepository();

  List<ModelPricing> _catalog = List.from(kDefaultModelCatalog);
  late String _selectedModelId;

  late final TextEditingController _systemPromptCtrl;
  late final TextEditingController _userPromptCtrl;
  Timer? _debounceTimer;

  // Track last committed text to skip no-op rebuilds when text is unchanged
  String _debouncedSystemText = '';
  String _debouncedUserText = '';

  ExecutionMode _mode = ExecutionMode.agent;
  ReasoningPreset _reasoningEffort = ReasoningPreset.medium;

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
  bool _showTurnByTurnTable = false;
  int _batchMultiplier = 1; // 1, 1000, 100000
  bool _isSyncing = false;
  String? _lastSyncStatus;

  // Memoized simulations for current state
  List<SimulationBreakdown>? _cachedSimulations;

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
    _debouncedSystemText = _systemPromptCtrl.text;
    _debouncedUserText = _userPromptCtrl.text;

    _systemPromptCtrl.addListener(_onInputChanged);
    _userPromptCtrl.addListener(_onInputChanged);
    _loadSavedPricingCatalog();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _systemPromptCtrl.dispose();
    _userPromptCtrl.dispose();
    super.dispose();
  }

  void _invalidateSimulations() {
    _cachedSimulations = null;
  }

  void _onInputChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      final newSys = _systemPromptCtrl.text;
      final newUsr = _userPromptCtrl.text;
      // Skip no-op rebuilds when text is unchanged (e.g., cursor/selection changes)
      if (newSys == _debouncedSystemText && newUsr == _debouncedUserText) {
        return;
      }
      setState(() {
        _debouncedSystemText = newSys;
        _debouncedUserText = newUsr;
        _invalidateSimulations();
      });
    });
  }

  ModelPricing get _activeModel => _catalog.firstWhere(
        (m) => m.id == _selectedModelId,
        orElse: () => _catalog.first,
      );

  SimulationRequest _buildRequestForModel(ModelPricing model) {
    return SimulationRequest(
      model: model,
      systemText: _debouncedSystemText,
      userText: _debouncedUserText,
      mode: _mode,
      reasoningEffort: _reasoningEffort,
      agentSteps: _agentSteps,
      toolPayloadTokensPerStep: _toolPayloadTokensPerStep.round(),
      visibleOutputTokensPerStep: _visibleOutputTokensPerStep.round(),
      contextCachingEnabled: _contextCachingEnabled,
      imageCount: _imageCount,
      pdfPageCount: _pdfPageCount,
      mediaMinutes: _mediaMinutes,
    );
  }

  List<SimulationBreakdown> _getOrComputeSimulations() {
    return _cachedSimulations ??= _catalog
        .map((m) => _simulationEngine.simulate(_buildRequestForModel(m)))
        .toList(growable: false);
  }

  // --------------------------------------------------------------------------
  // PERSISTENCE (WITH SCHEMA VERSIONING) & LIVE OPENROUTER PRICING SYNC
  // --------------------------------------------------------------------------

  Future<void> _loadSavedPricingCatalog() async {
    final result = await _catalogRepo.loadSavedCatalog();
    if (!mounted) return;
    setState(() {
      _catalog = result.catalog;
      if (!_catalog.any((m) => m.id == _selectedModelId)) {
        _selectedModelId = _catalog.first.id;
      }
      if (result.statusMessage != null) {
        _lastSyncStatus = result.statusMessage;
      }
      _invalidateSimulations();
    });
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
      _invalidateSimulations();
    });
    await _catalogRepo.saveCatalog(updated, statusLabel);
  }

  Future<void> _syncLiveOpenRouterPricing() async {
    setState(() => _isSyncing = true);
    try {
      final syncResult = await _catalogRepo.syncLiveOpenRouterPricing(_catalog);
      if (!mounted) return;
      setState(() {
        _catalog = syncResult.catalog;
        if (!_catalog.any((m) => m.id == _selectedModelId)) {
          _selectedModelId = _catalog.first.id;
        }
        _lastSyncStatus = syncResult.timestampLabel;
        _invalidateSimulations();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Synced live pricing from OpenRouter API (${syncResult.matchedCount} preset slugs matched).',
          ),
          backgroundColor: const Color(0xFF059669),
        ),
      );
    } catch (e) {
      if (mounted) {
        final webCorsHint = kIsWeb
            ? ' On Web, this may be blocked by browser CORS policies; use Schema / JSON to paste rates manually.'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Live sync unreachable ($e). Using local pricing catalog.$webCorsHint',
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
  // PRICING SCHEMA & JSON OVERRIDE MODAL
  // --------------------------------------------------------------------------

  void _openPricingSchemaModal() {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return PricingSchemaDialog(
          initialCatalog: _catalog,
          schemaVersion: CatalogRepository.currentSchemaVersion,
          onSaveCatalog: _saveCatalogToPrefs,
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // UI BUILDERS
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final allSimulations = _getOrComputeSimulations();
    final activeSim = allSimulations.firstWhere(
      (s) => s.model.id == _selectedModelId,
      orElse: () => allSimulations.first,
    );

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
                      'Heuristic BPE Estimator (±15%) • Split Cache Write/Read Engine',
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
                    setState(() {
                      _mode = val.first;
                      _invalidateSimulations();
                    });
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
                    key: ValueKey(_selectedModelId),
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
    final combinedText = '$_debouncedSystemText\n$_debouncedUserText'.trim();
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
                      label:
                          const Text('Clear', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
            if (sim.textWasTruncated)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF78350F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Input exceeds 200,000 characters — truncated cleanly at surrogate boundary for real-time BPE estimation.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFDE68A)),
                ),
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
                  '${_formatNumber(sim.systemTextTokens)} tokens',
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
                  '${_formatNumber(sim.userTextTokens)} tokens • ${_formatNumber(combinedText.length)} chars',
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
                        LegendBadge(
                          color: Color(0xFF312E81),
                          label: 'Word / Subword',
                        ),
                        LegendBadge(
                          color: Color(0xFF78350F),
                          label: 'Operator / Punct',
                        ),
                        LegendBadge(
                          color: Color(0xFF064E3B),
                          label: 'Numeric Literal',
                        ),
                        LegendBadge(
                          color: Color(0xFF701A75),
                          label: 'CJK / Emoji Cluster (2-4× BPE)',
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
                              case TokenKind.emojiOrNonLatin:
                                bg = const Color(0xFF701A75);
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
                                span.bpeWeight > 1
                                    ? '${span.text} (×${span.bpeWeight})'
                                    : span.text,
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
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
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
                        onChanged: (v) {
                          setState(() {
                            _contextCachingEnabled = v;
                            _invalidateSimulations();
                          });
                        },
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
            LayoutBuilder(
              builder: (context, box) {
                final bool compactLabels = box.maxWidth < 460;
                return SegmentedButton<ReasoningPreset>(
                  showSelectedIcon: !compactLabels,
                  segments: ReasoningPreset.values.map((effort) {
                    return ButtonSegment<ReasoningPreset>(
                      value: effort,
                      label: Text(
                        compactLabels ? effort.shortLabel : effort.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  }).toList(),
                  selected: {_reasoningEffort},
                  onSelectionChanged: (val) {
                    setState(() {
                      _reasoningEffort = val.first;
                      _invalidateSimulations();
                    });
                  },
                );
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
                onChanged: (v) {
                  setState(() {
                    _agentSteps = v.round();
                    _invalidateSimulations();
                  });
                },
              ),
              _buildSliderRow(
                label: 'Avg Tool Observation Payload Added per Step',
                valueText:
                    '${_formatNumber(_toolPayloadTokensPerStep.round())} tokens/step',
                value: _toolPayloadTokensPerStep,
                min: 0,
                max: 10000,
                divisions: 40,
                onChanged: (v) {
                  setState(() {
                    _toolPayloadTokensPerStep = v;
                    _invalidateSimulations();
                  });
                },
              ),
            ],

            _buildSliderRow(
              label: isAgent
                  ? 'Visible Model Output per Step'
                  : 'Expected Visible Completion Output',
              valueText:
                  '${_formatNumber(_visibleOutputTokensPerStep.round())} tokens',
              value: _visibleOutputTokensPerStep,
              min: 100,
              max: 8000,
              divisions: 79,
              onChanged: (v) {
                setState(() {
                  _visibleOutputTokensPerStep = v;
                  _invalidateSimulations();
                });
              },
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
              Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
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
    final model = sim.model;
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
                  subtitle: '~${_formatNumber(model.tokensPerImage)} tok / img',
                  count: _imageCount,
                  onChanged: (v) {
                    setState(() {
                      _imageCount = v;
                      _invalidateSimulations();
                    });
                  },
                ),
                _buildCounterBox(
                  title: 'PDF Pages',
                  subtitle:
                      '~${_formatNumber(model.tokensPerPdfPage)} tok / page',
                  count: _pdfPageCount,
                  onChanged: (v) {
                    setState(() {
                      _pdfPageCount = v;
                      _invalidateSimulations();
                    });
                  },
                ),
                _buildCounterBox(
                  title: 'Video / Audio',
                  subtitle:
                      '~${_formatNumber(model.tokensPerMediaMinute)} tok / min',
                  count: _mediaMinutes,
                  onChanged: (v) {
                    setState(() {
                      _mediaMinutes = v;
                      _invalidateSimulations();
                    });
                  },
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
      width: 215,
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
    final impactPct = sim.cacheImpactPercent;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    sim.model.name.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                      color: Color(0xFF818CF8),
                    ),
                    overflow: TextOverflow.ellipsis,
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
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 6,
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
                      if (impactPct.abs() >= 0.5)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: impactPct > 0
                                ? const Color(0xFF065F46)
                                : const Color(0xFF7F1D1D),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            impactPct > 0
                                ? 'Input Cache Saved ${impactPct.toStringAsFixed(1)}%'
                                : 'Cache Penalty +${impactPct.abs().toStringAsFixed(1)}%',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: impactPct > 0
                                  ? const Color(0xFF6EE7B7)
                                  : const Color(0xFFFCA5A5),
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
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                const Text(
                  'Batch Projection Scale:',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF9CA3AF)),
                ),
                SegmentedButton<int>(
                  showSelectedIcon: false,
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

            // Granular Token & Cost Ledger (Fix 1.3: separated Turn-1 Write vs Uncached Input)
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
              label: 'Uncached Dynamic Input & History',
              tokens: '${_formatNumber(sim.totalBilledInputTokens)} tok',
              cost: _formatCurrency(sim.uncachedInputCost),
            ),
            _buildLedgerRow(
              label: 'Turn-1 Prefix Cache Write',
              tokens: '${_formatNumber(sim.totalCacheWriteTokens)} write tok',
              cost: _formatCurrency(sim.cacheWriteCost),
              highlightColor: const Color(0xFF38BDF8),
            ),
            _buildLedgerRow(
              label: 'Turn-2..N Prefix Cache Reads',
              tokens: '${_formatNumber(sim.totalCachedReadTokens)} read tok',
              cost: _formatCurrency(sim.cacheReadCost),
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

            // Per-Turn Expansion Toggle (Review Question 5)
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () =>
                  setState(() => _showTurnByTurnTable = !_showTurnByTurnTable),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Inspect Compounding Turn-by-Turn Ledger (${sim.turns.length} steps)',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF818CF8),
                      ),
                    ),
                    Icon(
                      _showTurnByTurnTable
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                      color: const Color(0xFF818CF8),
                    ),
                  ],
                ),
              ),
            ),
            if (_showTurnByTurnTable) _buildTurnByTurnExpansion(sim),

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
              onPressed: () async {
                final summary =
                    'Model: ${sim.model.name} (${_mode.name.toUpperCase()})\n'
                    'Peak Turn Context: ${_formatNumber(sim.peakTurnContextTokens)} tokens\n'
                    'Uncached Dynamic Input: ${_formatNumber(sim.totalBilledInputTokens)} tokens\n'
                    'Turn-1 Cache Write: ${_formatNumber(sim.totalCacheWriteTokens)} tokens\n'
                    'Turn-2..N Cache Reads: ${_formatNumber(sim.totalCachedReadTokens)} tokens\n'
                    'Output + Thinking: ${_formatNumber(sim.totalVisibleOutputTokens + sim.totalReasoningTokens)} tokens\n'
                    'Cost (1 Run): ${_formatCurrency(sim.totalCostSingleRun)}\n'
                    'Cost (${_formatNumber(_batchMultiplier)} Runs): ${_formatCurrency(scaledCost)}';
                try {
                  await Clipboard.setData(ClipboardData(text: summary));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('Copied cost telemetry report to clipboard.'),
                      ),
                    );
                  }
                } catch (err) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Clipboard access denied by browser/OS ($err).',
                        ),
                        backgroundColor: const Color(0xFFD97706),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy Telemetry Report'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTurnByTurnExpansion(SimulationBreakdown sim) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F19),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 210),
        child: SingleChildScrollView(
          child: Column(
            children: sim.turns.map((t) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Turn ${t.turnNumber}${t.isLongContextTier ? " (Tier+)" : ""}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: t.isLongContextTier
                            ? const Color(0xFFFBBF24)
                            : const Color(0xFFD1D5DB),
                      ),
                    ),
                    Text(
                      'Ctx: ${_formatNumber(t.totalContextTokens)} tok',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                    Text(
                      _formatCurrency(t.turnCost),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
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
                  DataColumn(label: Text('Input Cache Impact')),
                ],
                rows: simulations.map((sim) {
                  final isSelected = sim.model.id == _selectedModelId;
                  final pct = sim.cacheImpactPercent;
                  String cacheLabel = 'neutral (0%)';
                  Color cacheColor = const Color(0xFF6B7280);
                  if (pct >= 0.5) {
                    cacheLabel = 'saved ${pct.toStringAsFixed(1)}%';
                    cacheColor = const Color(0xFF34D399);
                  } else if (pct <= -0.5) {
                    cacheLabel = 'cost +${pct.abs().toStringAsFixed(1)}%';
                    cacheColor = const Color(0xFFF87171);
                  }

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
                          cacheLabel,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                            color: cacheColor,
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
  // FORMATTING HELPERS (SAFE FOR NEGATIVES & CONSISTENT PRECISION)
  // --------------------------------------------------------------------------

  String _formatNumber(int n) {
    final bool isNegative = n < 0;
    final s = n.abs().toString();
    final buf = StringBuffer();
    if (isNegative) buf.write('-');
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _formatCurrency(double val) {
    if (val == 0) return '\$0.00';
    final sign = val < 0 ? '-' : '';
    final absVal = val.abs();
    if (absVal < 0.01) return '$sign\$${absVal.toStringAsFixed(5)}';
    if (absVal < 1.0) return '$sign\$${absVal.toStringAsFixed(4)}';
    return '$sign\$${absVal.toStringAsFixed(2)}';
  }
}