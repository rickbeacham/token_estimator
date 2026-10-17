import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../pricing/model_pricing.dart';

// ============================================================================
// DEDICATED STATEFUL DIALOG FOR JSON PRICING SCHEMA
// ============================================================================

class PricingSchemaDialog extends StatefulWidget {
  final List<ModelPricing> initialCatalog;
  final int schemaVersion;
  final Future<void> Function(List<ModelPricing>, String) onSaveCatalog;

  const PricingSchemaDialog({
    super.key,
    required this.initialCatalog,
    required this.schemaVersion,
    required this.onSaveCatalog,
  });

  @override
  State<PricingSchemaDialog> createState() => _PricingSchemaDialogState();
}

class _PricingSchemaDialogState extends State<PricingSchemaDialog> {
  late final TextEditingController _jsonController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final payload = {
      'schema': widget.schemaVersion,
      'models': widget.initialCatalog.map((m) => m.toJson()).toList(),
    };
    _jsonController = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(payload),
    );
  }

  @override
  void dispose() {
    _jsonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = math.min(720.0, math.max(280.0, viewport.width - 32));
    // Accounts for AlertDialog vertical insets (48) + title (~56) + actions (~52) + slack
    final dialogHeight = math.max(
      120.0,
      math.min(480.0, viewport.height - 220),
    );

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
        width: dialogWidth,
        height: dialogHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Edit per-1M token rates, multimodal weights, and Turn-1 Cache Write vs. Turn-N Cache Read rates. Changes persist locally with schema versioning.',
              style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 12),
            if (_errorText != null)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF7F1D1D),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _errorText!,
                  style: const TextStyle(
                    color: Color(0xFFFCA5A5),
                    fontSize: 12,
                  ),
                ),
              ),
            Expanded(
              child: TextField(
                controller: _jsonController,
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
            await widget.onSaveCatalog(
              List.from(kDefaultModelCatalog),
              'Reset to factory defaults',
            );
            if (context.mounted) Navigator.of(context).pop();
          },
          icon: const Icon(Icons.restore, size: 18),
          label: const Text('Reset Defaults'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () async {
            try {
              final dynamic decoded = jsonDecode(_jsonController.text);
              List<dynamic> rawList;
              if (decoded is Map<String, dynamic>) {
                final schema = (decoded['schema'] as num?)?.toInt();
                if (schema != null && schema != widget.schemaVersion) {
                  throw FormatException(
                    'Unsupported schema version $schema (expected ${widget.schemaVersion}).',
                  );
                }
                rawList = (decoded['models'] as List<dynamic>?) ?? [];
              } else if (decoded is List<dynamic>) {
                rawList = decoded;
              } else {
                throw const FormatException(
                  'Expected top-level schema object or list of models.',
                );
              }

              final parsed = rawList
                  .map((e) => ModelPricing.fromJson(e as Map<String, dynamic>))
                  .toList();
              if (parsed.isEmpty) {
                throw const FormatException('Model catalog cannot be empty.');
              }
              await widget.onSaveCatalog(
                parsed,
                'Saved custom JSON overrides (schema v${widget.schemaVersion})',
              );
              if (context.mounted) Navigator.of(context).pop();
            } catch (e) {
              setState(() {
                _errorText = 'Invalid JSON Schema: $e';
              });
            }
          },
          icon: const Icon(Icons.save_outlined, size: 18),
          label: const Text('Save & Persist Schema'),
        ),
      ],
    );
  }
}
