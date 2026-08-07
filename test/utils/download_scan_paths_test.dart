import 'package:PiliPlus/utils/download_scan_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('回退到内置时仍包含 customPath（SD）且 SD 排前（权威）', () {
    // Bug1 核心修复 + Spec(c)：当 downloadPath 解析回退到内置，仍要扫 SD customPath，
    // 且 SD（用户选定位置）应排在内置之前作为权威源——first-wins 时 SD 的已完成条目
    // 胜出，避免内置陈旧未完成 entry.json 遮蔽 SD 已完成条目。
    expect(
      DownloadScanPaths.compute(
        resolvedDownloadPath:
            '/storage/emulated/0/Android/data/pkg/files/PiliPlus/download',
        customPath: '/storage/XXXX-XXXX/PiliPlus/download',
      ),
      [
        '/storage/XXXX-XXXX/PiliPlus/download',
        '/storage/emulated/0/Android/data/pkg/files/PiliPlus/download',
      ],
    );
  });

  test('customPath 与 resolved 相同时不重复', () {
    expect(
      DownloadScanPaths.compute(
        resolvedDownloadPath: '/sd/PiliPlus/download',
        customPath: '/sd/PiliPlus/download',
      ),
      ['/sd/PiliPlus/download'],
    );
  });

  test('extraScanPaths 追加并去重（含与 resolved/customPath 重复）', () {
    expect(
      DownloadScanPaths.compute(
        resolvedDownloadPath: '/internal',
        customPath: '/sd',
        extraScanPaths: ['/old', '/internal', '/sd'],
      ),
      ['/sd', '/internal', '/old'],
    );
  });

  test('customPath 为空时只用 resolved + extra', () {
    expect(
      DownloadScanPaths.compute(
        resolvedDownloadPath: '/internal',
        customPath: null,
        extraScanPaths: ['/old'],
      ),
      ['/internal', '/old'],
    );
  });

  test('全部为空/默认时至少返回 resolved', () {
    expect(
      DownloadScanPaths.compute(
        resolvedDownloadPath: '/internal',
        customPath: null,
        extraScanPaths: null,
      ),
      ['/internal'],
    );
  });
}
