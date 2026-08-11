import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'recording/recording_keep_alive.dart';
import 'ui/library_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  RecordingKeepAlive.init();
  runApp(const ProviderScope(child: A7App()));
}

class A7App extends StatelessWidget {
  const A7App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'A7 Recorder',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(), // 全屏共用设计 token(保留 teal 主色 + 中性偏暖背景)
      home: const LibraryScreen(),
    );
  }
}
