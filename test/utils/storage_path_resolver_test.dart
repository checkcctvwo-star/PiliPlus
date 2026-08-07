import 'package:PiliPlus/utils/storage_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joinDownloadPath 拼接 PiliPlus/download', () {
    expect(StoragePathResolver.joinDownloadPath('/storage/emulated/0'),
        '/storage/emulated/0/PiliPlus/download');
  });

  test('resolve accessible 为真即用 customPath', () {
    // 信任 customPathAccessible（文件访问事实判据），而非 permission_handler
    // 可能误报的 granted 状态（见 permission_handler#1169）。
    expect(
      StoragePathResolver.resolve(
        customPath: '/storage/XXXX-XXXX/PiliPlus/download',
        customPathAccessible: true,
        fallbackPath: '/fallback',
      ),
      '/storage/XXXX-XXXX/PiliPlus/download',
    );
  });

  test('resolve accessible 为假回退', () {
    expect(
      StoragePathResolver.resolve(
        customPath: '/storage/XXXX-XXXX/PiliPlus/download',
        customPathAccessible: false,
        fallbackPath: '/fallback',
      ),
      '/fallback',
    );
  });

  test('resolve customPath 为空回退', () {
    expect(
      StoragePathResolver.resolve(
        customPath: null,
        customPathAccessible: true,
        fallbackPath: '/fallback',
      ),
      '/fallback',
    );
  });

  test('resolve customPath 为空字符串回退', () {
    expect(
      StoragePathResolver.resolve(
        customPath: '',
        customPathAccessible: true,
        fallbackPath: '/fallback',
      ),
      '/fallback',
    );
  });
}
