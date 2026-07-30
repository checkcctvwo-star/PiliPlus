import 'package:PiliPlus/utils/storage_path_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joinDownloadPath 拼接 PiliPlus/download', () {
    expect(StoragePathResolver.joinDownloadPath('/storage/emulated/0'),
        '/storage/emulated/0/PiliPlus/download');
  });

  test('resolve 用自定义路径当授权且可访问', () {
    expect(
      StoragePathResolver.resolve(
        customPath: '/storage/XXXX-XXXX/PiliPlus/download',
        permissionGranted: true,
        customPathAccessible: true,
        fallbackPath: '/fallback',
      ),
      '/storage/XXXX-XXXX/PiliPlus/download',
    );
  });

  test('resolve 未授权回退', () {
    expect(
      StoragePathResolver.resolve(
        customPath: '/storage/XXXX-XXXX/PiliPlus/download',
        permissionGranted: false,
        customPathAccessible: true,
        fallbackPath: '/fallback',
      ),
      '/fallback',
    );
  });

  test('resolve 自定义路径不可访问回退', () {
    expect(
      StoragePathResolver.resolve(
        customPath: '/bad',
        permissionGranted: true,
        customPathAccessible: false,
        fallbackPath: '/fallback',
      ),
      '/fallback',
    );
  });

  test('resolve 自定义为空回退', () {
    expect(
      StoragePathResolver.resolve(
        customPath: null,
        permissionGranted: true,
        customPathAccessible: false,
        fallbackPath: '/fallback',
      ),
      '/fallback',
    );
  });
}
