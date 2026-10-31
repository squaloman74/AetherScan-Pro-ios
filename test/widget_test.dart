import 'package:flutter_test/flutter_test.dart';
import 'package:aetherscan_pro/main.dart';

void main() {
  testWidgets('AetherScan Pro App load smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const AetherScanProApp());
    expect(find.text('AetherScan '), findsOneWidget);
  });
}
