/// 计算下载扫描路径的纯函数。
///
/// 始终把用户选的 [customPath]（如外置 SD 卡路径）纳入扫描，即使
/// [resolvedDownloadPath] 因 SD 暂不可访问/权限误报而回退到内置存储。
/// 这样回退时仍能扫到 SD 上的 entry.json，避免「崩溃/重启后缓存消失」。
///
/// [customPath] 排在 [resolvedDownloadPath] 之前作为权威源：用户选定的位置
/// 状态优先，first-wins 去重时 SD 的（已完成）条目胜出，避免内置陈旧未完成
/// entry.json 遮蔽 SD 已完成条目。同时对 [extraScanPaths] 与上述路径去重，
/// 避免同一目录扫两遍产生重复条目。
abstract final class DownloadScanPaths {
  static List<String> compute({
    required String resolvedDownloadPath,
    String? customPath,
    List<String>? extraScanPaths,
  }) {
    final paths = <String>[];
    if (customPath != null && customPath.isNotEmpty) {
      paths.add(customPath);
    }
    if (!paths.contains(resolvedDownloadPath)) {
      paths.add(resolvedDownloadPath);
    }
    if (extraScanPaths != null) {
      for (final p in extraScanPaths) {
        if (p.isNotEmpty && !paths.contains(p)) paths.add(p);
      }
    }
    return paths;
  }
}
