# **token_estimator**
### *Wǔxíng Suànmín*
**AI Token & Agent Loop Cost Simulator**

![App Preview](https://via.placeholder.com/800x400/111827/FFFFFF?text=token_estimator+UI+Preview)

---

## **Overview**
**五行算缗 (Wǔxíng Suànmín)** is a cyclical cost-tracking system designed to simulate AI token consumption and agent loop expenses. This tool helps developers, researchers, and businesses estimate costs for AI-driven workflows, including multi-turn agent interactions, multimodal inputs, and reasoning effort.

---

## **Key Features**

### **1. Execution Modes**
- **Chat (1-Turn)** – Single-shot interaction (agent steps forced to 1, tool payload forced to 0).
- **Task / Agent Loop** – Multi-turn compounding context with adjustable step count, tool payload, and caching.
- **Segmented control** toggles between modes at the top of the dashboard.

### **2. Model Catalog & Selection**
- **5 preset frontier models** included:
  - Gemini 4 Argon (Google)
  - Gemini 3.x Flash (Google)
  - Claude Sonnet (Anthropic)
  - GPT-4o (OpenAI)
  - Llama / DeepSeek (Open Weights)
- **Primary Target Model dropdown** with inline pricing display.
- Each model includes:
  - Context window
  - Chars-per-token ratio
  - Base input/output/reasoning rates
  - Long-context threshold & pricing tiers
  - Cache write/read rates
  - Optional OpenRouter slug

### **3. Prompt Input (Split-Pane)**
- **System Instructions pane** (cached prefix) with live token counter.
- **Dynamic User Prompt pane** with token & character counters.
- Independent multi-line `TextField` for each input.
- **Clear button** resets both panes.
- **Live re-tokenization** as the user types.

### **4. Token Inspector (Optional)**
- Toggle via **FilterChip ("Inspect Subword Tokens")**.
- **Color-coded subword spans**:
  - Word / Subword (indigo)
  - Code / Punctuation (amber)
  - Numeric literal (green)
- **Legend badges** for each category.
- Capped at **400 spans** for performance.
- Whitespace spans hidden from display.

### **5. Tokenizer Engine**
- **Regex-based, content-aware tokenizer** (`TokenizerEngine`).
- Groups input into:
  - Whitespace runs (~1 token per 4 chars)
  - Numbers (~1 token per 3 digits)
  - Words/identifiers (BPE-like subword chunks)
- Merges leading whitespace with the following word (BPE-style).

### **6. Agent Loop Controls (Agent Mode Only)**
- **Context Caching** (on/off switch).
- **Autonomous Agent / Tool Steps slider** (1–25 turns).
- **Avg Tool Observation Payload** slider (0–10,000 tokens/step).
- **Visible Model Output per Step** slider (100–8,000 tokens).
- Sliders display live values in monospace typography.

### **7. Reasoning Effort Control**
- **Segmented control** with four levels:
  - Off (0)
  - Low (+1k / 1,024)
  - Med (+4k / 4,096)
  - High (+16k / 16,384)
- Applied per step and billed at the model’s reasoning output rate.

### **8. Multimodal Attachment Counters**
- **Three stepper boxes** for:
  - **Images** (~258 tok/image)
  - **PDF Pages** (~850 tok/page)
  - **Video / Audio** (~15,000 tok/minute)
- **Total multimodal tokens** displayed in the card header.
- All constants are **hard-coded**.

### **9. Cost Simulation Engine**
- **Per-model, turn-by-turn simulation** over the full agent loop.
- Tracks:
  - System + user + multimodal token split
  - Initial prompt tokens
  - Peak turn context
  - Total billed uncached input tokens
  - Total cached read tokens
  - Total visible output tokens
  - Total reasoning tokens
  - Uncached input cost, cache write/read cost
  - Visible output cost, reasoning output cost
  - Total single-run cost
  - Uncached baseline cost (for savings comparison)
- **Flags**:
  - `exceedsContextWindow`
  - `crossedLongContextTier`
- **Tiered pricing** switches to above-threshold rates when context crosses the model’s long-context threshold.
- **Split cache pricing**:
  - Turn 1 billed at `cacheWritePer1M`
  - Turns 2..N billed at `cacheReadPer1M`
- **Reasoning cost fallback** – never drops below the output rate on long-context turns.

### **10. Live Pricing Sync (OpenRouter)**
- **"Sync Live Rates" button** in the AppBar.
- Fetches pricing from [OpenRouter API](https://openrouter.ai/api/v1/models).
- Matches local models to OpenRouter entries by `openRouterSlug`.
- Updates local rates for matched models only.
- Shows success/failure snackbar.
- **10-second timeout** with loading spinner.
- Derives above-threshold rates heuristically (`liveIn * 2.0 / liveOut * 1.5`).

### **11. Pricing Schema / JSON Editor**
- **"Schema / JSON" button** in the AppBar opens a modal.
- **Full JSON dump** of the current catalog (pretty-printed, 2-space indent).
- **Editable TextField** with monospace styling.
- **Save & Persist Schema** – validates, parses, and persists.
- **Reset Defaults** – restores `kDefaultModelCatalog`.
- **Cancel** – discards edits.
- **Inline error panel** for invalid JSON.
- Rejects empty catalogs.

### **12. Persistence (SharedPreferences)**
- Custom catalog saved under `custom_pricing_catalog_v1`.
- Last sync status saved under `last_pricing_sync_time_v1`.
- Loaded on app start; falls back to defaults if missing/unparseable.
- If saved catalog lacks the selected model, selection resets to the first entry.
- `ModelPricing.toJson / fromJson` with defensive defaults.

### **13. Cost Telemetry Panel (Right Column)**
- **Hero cost display** – large monospace currency figure for the workflow.
- **Cache savings badge** – percentage saved vs. uncached baseline (clamped ≥0).
- **Long-context warning banner** – amber when tier is crossed.
- **Context overflow badge** – red pill if peak context exceeds the window.
- **Peak context badge** – green pill showing peak / window otherwise.
- **Granular Token & Billing Ledger**:
  - Uncached input / compounding history (tokens + cost)
  - Turn-1 cache write + Turn-N cache reads (tokens + cost, green)
  - Visible model output (tokens + cost)
  - Hidden internal thinking / reasoning (tokens + cost, amber)
- **Active Schema Rates card** – monospace summary of base & tiered rates.

### **14. Batch Projection**
- **Segmented control**: 1 Run / 1k Runs / 100k Runs.
- Multiplies hero cost and per-model **"Scaled Batch Cost"** column.
- Reflected in:
  - Hero label (`ESTIMATED COST (N RUNS)`)
  - Comparison-matrix header
  - Mobile pinned bar

### **15. Copy Telemetry Report**
- **"Copy Telemetry Report" button** copies a plain-text summary to clipboard.
- Includes:
  - Model + mode
  - Peak turn context
  - Billed uncached input tokens
  - Cached read hits
  - Output + thinking tokens
  - 1-run cost
  - Batch-scaled cost
- Success snackbar on copy.

### **16. Side-by-Side Comparison Matrix**
- **DataTable** listing every model in the catalog.
- Columns:
  - Model
  - Base In/Out
  - Cache Write/Read
  - Peak Context
  - 1-Run Cost
  - Scaled Batch Cost
  - Cache Savings
- **Clicking a row** selects that model as the primary target.
- **Red error icon** for models that overflow their context window.
- **Highlighted row** matches the currently selected model.
- Horizontally scrollable for narrow viewports.

### **17. Responsive Layout**
- **Wide layout (≥960 px)**:
  - Two-column split (configuration left, telemetry right)
  - Comparison matrix below
- **Compact layout (<960 px)**:
  - Single-column scroll
  - Pinned mobile summary bar at the bottom
- **Mobile pinned bar** shows:
  - Model name
  - Mode
  - Peak tokens
  - Scaled cost
- `SafeArea(top: false)` respects home indicators on iOS.

### **18. Theming**
- **Material 3, dark-only**.
- **Custom dark color scheme**:
  - Indigo primary
  - Emerald secondary
  - Amber tertiary
- **Scaffold background**: `#0B0F19`
- **Cards**: `#111827` with subtle borders.
- **Custom CardThemeData** (rounded 14 px, no elevation).
- **Custom InputDecorationTheme** (filled, rounded 10 px, focused indigo border).
- **Monospace typography** for numeric readouts.

### **19. App Bar & Status**
- **Custom icon + title block**.
- **Subtitle** shows last sync status or engine tagline.
- **Overflow ellipsis** for narrow windows.
- **Action buttons**:
  - Sync Live Rates (with inline spinner)
  - Schema / JSON

### **20. Formatting Helpers**
- `_formatNumber` – Thousands separators for token counts.
- `_formatCurrency` – Adaptive decimal precision:
  - < $0.01 → 5 decimals
  - < $1.00 → 4 decimals
  - Otherwise → 2 decimals
  - $0 → $0.0000

---

## **Summary by Category**

| **Category**               | **Count** |
|----------------------------|----------|
| Input modes                | 2        |
| Preset models              | 5        |
| Reasoning levels           | 4        |
| Multimodal input types     | 3        |
| Batch scales               | 3        |
| Comparison columns         | 7        |
| Ledger rows               | 4        |
| Persistence keys           | 2        |
| External integrations      | 1 (OpenRouter) |
| Modal editors              | 1        |

---

## **Missing Features (Gaps)**
❌ No **per-turn breakdown view** (engine computes turns internally but doesn’t surface them).
❌ No **export to CSV/file** (only clipboard copy).
❌ No **multi-model cost differential view** (e.g., "switching from Claude to Flash saves $X").
❌ No **user-defined custom models via form** (only JSON editor).
❌ No **provider/model filter or search** in the dropdown.
❌ No **token-count target budget** (e.g., "warn me above 100k tokens").
❌ No **comparison against historical saved runs**.
❌ No **i18n / locale formatting** (currency hard-coded to $).
❌ No **dark/light toggle** (dark mode only).
❌ No **test coverage** (no `test/` folder).

---

## **Installation & Usage**
1. Clone the repository.
2. Run `flutter pub get`.
3. Execute `flutter run` (or build for your target platform).
4. Configure models, prompts, and agent settings.
5. Analyze cost estimates in real-time.

---

## **License**
MIT (see [LICENSE](LICENSE)).

---

## **Contributing**
Pull requests welcome! Report issues on [GitHub Issues](https://github.com/your-repo/issues).

---
**Built with ❤️ using Flutter & Material 3.**