# Changelog

All notable changes to the **AI Token & Agent Loop Cost Simulator** project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-10-16

### Added
- **Modular Package Architecture**: Split the monolithic `lib/main.dart` into focused domain layers:
  - `lib/pricing/model_pricing.dart` (`ModelPricing`, `ReasoningPreset`, `ExecutionMode`, default frontier catalog)
  - `lib/engine/tokenizer.dart` (`TokenizerEngine`, `TokenSpanItem`, `TokenKind`)
  - `lib/engine/simulator.dart` (`SimulationEngine`, `SimulationRequest`, `SimulationBreakdown`, `TurnBreakdown`)
  - `lib/data/catalog_repository.dart` (`CatalogRepository`, `CatalogLoadResult`, `OpenRouterSyncResult`)
  - `lib/ui/dashboard_screen.dart` & `lib/ui/widgets/` (`PricingSchemaDialog`, `LegendBadge`)
- **Per-Turn Compounding Context Ledger**: Added `TurnBreakdown` and an expandable turn-by-turn UI table to inspect context growth, tiered threshold crossings, and per-step costs across multi-turn agent loops.
- **Dedicated Turn-1 Cache Write Ledger**: Added `totalCacheWriteTokens` to `SimulationBreakdown` and a dedicated billing row (`Turn-1 Prefix Cache Write`) to separate static prefix creation from dynamic uncached history.
- **Per-Model Multimodal Token Weights**: Added `tokensPerImage`, `tokensPerPdfPage`, and `tokensPerMediaMinute` fields to `ModelPricing` (including JSON serialization) to accurately reflect provider-specific vision and document token rates across Gemini, Claude, GPT-4o, and open-weight models.
- **Schema Versioning for Local Persistence**: Wrapped persisted `SharedPreferences` catalog payloads in a versioned envelope (`{"schema": 2, "models": [...]}`) with automatic fallback to factory defaults on version mismatch.
- **Unit & Regression Test Suite**: Added `test/engine_test.dart` covering endpoint URI validation, UTF-16 surrogate boundary truncation, multi-char operator and ZWJ emoji tokenization, cache penalty math, and custom `TokenizerFn` dependency injection.

### Changed
- **Decoupled Simulation & Tokenization Engines**: Extracted simulation logic into `SimulationEngine.simulate(SimulationRequest)` with an injectable `TokenizerFn`, keeping `TokenizerEngine` strictly focused on text-to-span BPE estimation.
- **Hot-Path Simulation Memoization & Input Debouncing**:
  - Memoized `SimulationBreakdown` results in `EstimatorDashboard` (`_cachedSimulations`) so `build()` no longer re-tokenizes across all catalog models on every frame.
  - Added a 64-entry LRU cache (`_countCache`) inside `TokenizerEngine.estimateTokenCount` keyed on `(hashCode, length, charsPerToken)` plus `TokenizerEngine.clearCache()` for test isolation.
  - Added a `180ms` debounce timer on prompt text controllers and skipped no-op rebuilds when text is unchanged.
- **Surrogate-Safe Input Length Cap**: Added a `200,000` UTF-16 code unit cap (`TokenizerEngine.capInput`) with high-surrogate boundary protection (`0xD800..0xDBFF`) and an inline UI truncation banner.
- **Unicode, CJK, & Emoji ZWJ Tokenizer Improvements**:
  - Enabled `unicode: true` on `_tokenRegex` to support Latin-Extended, Cyrillic, CJK ideographs, and Hangul syllables.
  - Grouped multi-character code operators (`===`, `!==`, `>>>`, `->`, `=>`, `::`, `||`, `&&`) and markdown code fences (` ``` `) as single tokens.
  - Grouped Regional Indicator flag pairs, skin-tone modifiers, variation selectors, and Zero-Width Joiner (`\u200D`) emoji clusters into single spans with realistic BPE weights (3–4 tokens).
- **Signed Input Cache Impact (`cacheImpactPercent`)**:
  - Replaced `cacheSavingsPercent` (previously clamped at `0%`) with `cacheImpactPercent` scoped to `uncachedInputBaselineCost`.
  - Added red **Cache Penalty +X%** indicators in the hero card and explicit `saved X%` / `cost +X%` / `neutral (0%)` labels in the comparison matrix when Turn-1 cache write surcharges exceed Turn-2..N read savings.
- **Extensible `ReasoningPreset` Model**: Converted `ReasoningEffort` from a fixed enum to a value class (`ReasoningPreset`) with `shortLabel` support for narrow viewports.
- **Responsive Schema Override Dialog**: Extracted `PricingSchemaDialog` into a dedicated `StatefulWidget` that properly disposes its `TextEditingController` and calculates viewport-safe dimensions (`math.max(120.0, math.min(480.0, viewport.height - 220))`) to prevent vertical overflow on short windows.

### Fixed
- **OpenRouter Endpoint Construction & Sync Fallbacks**:
  - Constructed `openRouterModelsUri` via `Uri.https('openrouter.ai', kOpenRouterModelsPath)` to guarantee valid host/path resolution.
  - Updated live sync fallback logic to apply a `1.25x` Turn-1 cache write multiplier for Anthropic/Claude models when OpenRouter omits `input_cache_write`.
  - Added a Web-specific CORS troubleshooting hint (`kIsWeb`) when browser fetch fails.
- **Long-Context Tier False Positives**: Guarded `isLongContextTurn` so tiered pricing only triggers when `model.longContextThreshold < model.contextWindow`.
- **Negative Number & Currency Formatting**: Updated `_formatNumber` and `_formatCurrency` to safely format negative values and render `$0.00` consistently.
- **Clipboard Error Handling**: Added a fallback `SnackBar` alert if `Clipboard.setData` is rejected by OS or browser permissions.

---

## [1.0.0] - 2026-10-15

### Added
- Initial release of the **AI Token & Agent Loop Cost Simulator** (`lib/main.dart`)[cite: 1].
- Support for 1-Turn Chat and Multi-Turn Autonomous Agent Loop execution modes[cite: 1].
- Curated frontier model catalog (`Gemini 4 Argon`, `Gemini 3.x Flash`, `Claude Sonnet`, `GPT-4o`, `Llama / DeepSeek`) with base, long-context tiered, and split cache write/read rates[cite: 1].
- Split-pane System Prompt (cached prefix) and Dynamic User Prompt inputs with visual subword token inspection[cite: 1].
- Multimodal attachment calculators for images, PDF pages, and audio/video minutes[cite: 1].
- Live pricing synchronization with the OpenRouter Models API and local JSON schema overrides via `SharedPreferences`[cite: 1].
- Side-by-side Frontier Model Comparison Matrix with batch projection scaling (`1x`, `1,000x`, `100,000x`)[cite: 1].