import 'package:PiliPlus/utils/download_dedup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按 cid 去重保留首个', () {
    final entries = [
      _E(1, 'a'),
      _E(2, 'b'),
      _E(1, 'a2'), // 重复 cid
      _E(3, 'c'),
    ];
    final result = dedupeByCid<_E>(entries, (e) => e.cid);
    expect(result.map((e) => e.cid).toList(), [1, 2, 3]);
    expect(result[0].tag, 'a'); // 保留首个
  });

  test('空列表返回空', () {
    expect(dedupeByCid<_E>([], (e) => e.cid), isEmpty);
  });
}

class _E {
  final int cid;
  final String tag;
  _E(this.cid, this.tag);
}
