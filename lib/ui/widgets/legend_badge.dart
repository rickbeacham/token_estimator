import 'package:flutter/material.dart';

class LegendBadge extends StatelessWidget {
  final Color color;
  final String label;
  const LegendBadge({super.key, required this.color, required this.label});

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
