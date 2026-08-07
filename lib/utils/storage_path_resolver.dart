import 'package:path/path.dart' as path;

abstract final class StoragePathResolver {
  static String joinDownloadPath(String root) =>
      path.join(root, 'PiliPlus', 'download');

  static String resolve({
    required String? customPath,
    required bool customPathAccessible,
    required String fallbackPath,
  }) {
    if (customPath != null &&
        customPath.isNotEmpty &&
        customPathAccessible) {
      return customPath;
    }
    return fallbackPath;
  }
}
