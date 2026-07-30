import 'package:PiliPlus/utils/storage_volume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatBytes 格式化', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(1048576), '1.0 MB');
    expect(formatBytes(28345678901), '26.4 GB');
  });

  test('StorageVolume.fromMap 解析', () {
    final v = StorageVolume.fromMap({
      'path': '/storage/XXXX-XXXX',
      'name': 'SD 卡',
      'isRemovable': true,
      'totalBytes': 64000000000,
      'availableBytes': 12100000000,
    });
    expect(v.path, '/storage/XXXX-XXXX');
    expect(v.name, 'SD 卡');
    expect(v.isRemovable, true);
    expect(v.totalBytes, 64000000000);
    expect(v.availableBytes, 12100000000);
  });
}
