import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/main.dart';

void main() {
  testWidgets('app boots to 我的会议(战情台)home', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: A7App()));
    await tester.pump(); // 让 store 异步加载(path_provider 在测试里被 catch,空库)
    expect(find.text('我的会议'), findsOneWidget);
    expect(find.text('开始会议'), findsOneWidget); // 底部主操作入口
  });
}
