import 'package:flutter_test/flutter_test.dart';
import 'package:token_estimator/main.dart';

void main() {
  testWidgets('TokenEstimatorApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const TokenEstimatorApp());

    // Verify that the simulator dashboard header renders
    expect(find.text('AI Token & Agent Loop Cost Simulator'), findsOneWidget);
  });
} 