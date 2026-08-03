import 'package:flutter/material.dart';

/// 全屏共用的「设计 token」:颜色 / 间距 / 圆角 / 字号层级 / 卡片样式。
///
/// 2-UI-a 起先在「会中屏」落地,后续「首页 / 详情」棒复用同一套,保证视觉统一。
/// 基调:teal 主色 + 中性偏暖背景,圆角卡片、克制阴影 —— 专业但不冷。
class AppColors {
  AppColors._();

  static const teal = Color(0xFF00897B); // 主色(略深 teal:正文/主按钮够对比)
  static const tealSoft = Color(0xFFE3F1EF); // 主色浅染(标签/头像底)

  static const bg = Color(0xFFFAFAF8); // 中性偏暖背景
  static const surface = Colors.white; // 卡片面
  static const line = Color(0xFFEAEAE3); // 描边 / 分隔线

  static const ink = Color(0xFF1F2421); // 正文(近黑偏暖)
  static const inkSoft = Color(0xFF5B635E); // 次要文字
  static const inkFaint = Color(0xFF9AA09B); // 辅助 / 占位文字

  static const cueBg = Color(0xFFFFFCF0); // 小抄卡底(暖黄,克制)
  static const cueAccent = Color(0xFFD9962B); // 小抄强调(琥珀)

  static const adviseBg = Color(0xFFEFF4FE); // 主动提示卡底(浅蓝)
  static const adviseAccent = Color(0xFF3B7DD8); // 主动提示强调

  static const danger = Color(0xFFD9534F); // 错误 / 录音点
  static const dangerBg = Color(0xFFFCEDEC); // 错误卡底

  static const ok = Color(0xFF2E9E5B); // 已连接 / 成功(绿)
  static const okBg = Color(0xFFEAF6EF);
  static const warn = Color(0xFFE08A2B); // 低电 / 告警(橙)
  static const warnBg = Color(0xFFFCF2E6);
}

/// 间距阶梯(4 的倍数为主)。
class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
}

/// 圆角阶梯。
class AppRadius {
  AppRadius._();
  static const card = 16.0;
  static const field = 12.0;
  static const chip = 8.0;
}

/// 三级字号 + 常用辅助样式。
class AppText {
  AppText._();
  static const title =
      TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.ink, height: 1.3);
  static const section = TextStyle(
      fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.inkSoft, letterSpacing: 0.2);
  static const body = TextStyle(fontSize: 15, color: AppColors.ink, height: 1.45);
  static const bodyLarge = TextStyle(fontSize: 16, color: AppColors.ink, height: 1.55);
  static const caption = TextStyle(fontSize: 12, color: AppColors.inkSoft, height: 1.35);
  static const faint = TextStyle(fontSize: 14, color: AppColors.inkFaint, height: 1.4);
}

class AppTheme {
  AppTheme._();

  /// 克制的浮起阴影(只给「主角」卡片用,其它用描边即可)。
  static const List<BoxShadow> softShadow = [
    BoxShadow(color: Color(0x0F101828), blurRadius: 14, offset: Offset(0, 4)),
  ];

  /// 统一卡片底:圆角 + 描边;[elevated] 时叠一层很轻的阴影。
  static BoxDecoration cardDecoration({
    Color color = AppColors.surface,
    Color? border,
    bool elevated = false,
  }) =>
      BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: border ?? AppColors.line),
        boxShadow: elevated ? softShadow : null,
      );

  /// 全局浅色主题:保留 teal 主色,换中性偏暖背景 + 扁平暖色 AppBar + 统一输入框。
  /// 只动「表现层 token」,不改任何屏的布局与逻辑。
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(seedColor: AppColors.teal);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: AppText.title,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        hintStyle: AppText.faint,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
            borderSide: const BorderSide(color: AppColors.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
            borderSide: const BorderSide(color: AppColors.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.field),
            borderSide: const BorderSide(color: AppColors.teal, width: 1.4)),
      ),
      dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 24),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
