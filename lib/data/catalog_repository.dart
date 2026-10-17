import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../pricing/model_pricing.dart';

// ============================================================================
// PERSISTENCE (WITH SCHEMA VERSIONING) & LIVE OPENROUTER PRICING SYNC
// ============================================================================

const String kOpenRouterModelsPath = '/api/v1/models';

/// OpenRouter models endpoint. Constructed via [Uri.https] so the host and
/// path are validated at construction rather than at request time.
final Uri openRouterModelsUri = Uri.https(
  'openrouter.ai',
  kOpenRouterModelsPath,
);

class CatalogLoadResult {
  final List<ModelPricing> catalog;
  final String? statusMessage;
  const CatalogLoadResult({required this.catalog, this.statusMessage});
}

class OpenRouterSyncResult {
  final List<ModelPricing> catalog;
  final int matchedCount;
  final String timestampLabel;

  const OpenRouterSyncResult({
    required this.catalog,
    required this.matchedCount,
    required this.timestampLabel,
  });
}

class CatalogRepository {
  static const String prefsCatalogKey = 'custom_pricing_catalog_v2';
  static const String prefsLastSyncKey = 'last_pricing_sync_time_v2';
  static const int currentSchemaVersion = 2;

  final http.Client _httpClient;

  CatalogRepository({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  Future<CatalogLoadResult> loadSavedCatalog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString(prefsCatalogKey);
      final savedTime = prefs.getString(prefsLastSyncKey);
      if (savedJson != null && savedJson.isNotEmpty) {
        final dynamic decoded = jsonDecode(savedJson);
        if (decoded is Map<String, dynamic>) {
          final int? schema = (decoded['schema'] as num?)?.toInt();
          if (schema == currentSchemaVersion && decoded['models'] is List) {
            final loaded = (decoded['models'] as List<dynamic>)
                .map((e) => ModelPricing.fromJson(e as Map<String, dynamic>))
                .toList();
            if (loaded.isNotEmpty) {
              return CatalogLoadResult(
                catalog: loaded,
                statusMessage: savedTime ?? 'Loaded custom local catalog',
              );
            }
          } else {
            return CatalogLoadResult(
              catalog: List.from(kDefaultModelCatalog),
              statusMessage:
                  'Schema updated to v$currentSchemaVersion (reset to factory defaults)',
            );
          }
        }
      }
    } catch (_) {
      // Fallback silently to default catalog
    }
    return CatalogLoadResult(catalog: List.from(kDefaultModelCatalog));
  }

  Future<void> saveCatalog(
    List<ModelPricing> updated,
    String statusLabel,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = {
        'schema': currentSchemaVersion,
        'models': updated.map((m) => m.toJson()).toList(),
      };
      await prefs.setString(prefsCatalogKey, jsonEncode(payload));
      await prefs.setString(prefsLastSyncKey, statusLabel);
    } catch (_) {}
  }

  Future<OpenRouterSyncResult> syncLiveOpenRouterPricing(
    List<ModelPricing> currentCatalog,
  ) async {
    final response = await _httpClient
        .get(openRouterModelsUri)
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

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
    final List<ModelPricing> updatedCatalog = currentCatalog.map((localModel) {
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
        final bool isAnthropicStyle =
            localModel.provider.toLowerCase().contains('anthropic') ||
            slug.toLowerCase().contains('claude') ||
            localModel.cacheWritePer1M > localModel.inputPer1M;
        return localModel.copyWith(
          contextWindow: liveContext ?? localModel.contextWindow,
          inputPer1M: liveIn,
          outputPer1M: liveOut,
          reasoningOutputPer1M: liveReason ?? liveOut,
          inputAboveThresholdPer1M: liveIn * 2.0,
          outputAboveThresholdPer1M: liveOut * 1.5,
          cacheWritePer1M:
              liveCacheWrite ?? (isAnthropicStyle ? liveIn * 1.25 : liveIn),
          cacheReadPer1M: liveCacheRead ?? (liveIn * 0.25),
        );
      }
      return localModel;
    }).toList();

    final now = DateTime.now();
    final timestamp =
        'Live synced ($matchedCount models) at ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    await saveCatalog(updatedCatalog, timestamp);

    return OpenRouterSyncResult(
      catalog: updatedCatalog,
      matchedCount: matchedCount,
      timestampLabel: timestamp,
    );
  }
}
