import 'package:PiliPlus/utils/download_scan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('重复 cid 的未完成条目去重为 1（Bug2 重扫/重复扫描修复）', () {
    // 当前实现里未完成条目直接 add 进 waitDownloadQueue、绕过去重 -> 重复。
    // dedup 应把完成+未完成统一按 cid 去重，首条优先。
    final entries = [
      _E(1, false, 'a'),
      _E(1, false, 'a2'), // 同 cid 重复
      _E(2, false, 'b'),
    ];
    final r = DownloadScan.dedup<_E>(
      entries,
      cidOf: (e) => e.cid,
      isCompletedOf: (e) => e.completed,
    );
    expect(r.incomplete.map((e) => e.cid), [1, 2]);
    expect(r.incomplete[0].tag, 'a'); // 首条优先
    expect(r.completed, isEmpty);
  });

  test('完成与未完成按 cid 统一去重，首条优先', () {
    final entries = [
      _E(1, true, 'done1'),
      _E(2, false, 'inc2'),
      _E(1, false, 'inc1-dup'), // 重复 cid=1，丢弃
      _E(2, true, 'done2-dup'), // 重复 cid=2，丢弃
    ];
    final r = DownloadScan.dedup<_E>(
      entries,
      cidOf: (e) => e.cid,
      isCompletedOf: (e) => e.completed,
    );
    expect(r.completed.map((e) => e.cid), [1]);
    expect(r.incomplete.map((e) => e.cid), [2]);
  });

  test('全部完成全进 completed', () {
    final entries = [_E(1, true, 'a'), _E(2, true, 'b')];
    final r = DownloadScan.dedup<_E>(
      entries,
      cidOf: (e) => e.cid,
      isCompletedOf: (e) => e.completed,
    );
    expect(r.completed.map((e) => e.cid), [1, 2]);
    expect(r.incomplete, isEmpty);
  });

  test('空列表返回空', () {
    final r = DownloadScan.dedup<_E>(
      [],
      cidOf: (e) => e.cid,
      isCompletedOf: (e) => e.completed,
    );
    expect(r.completed, isEmpty);
    expect(r.incomplete, isEmpty);
  });
}

class _E {
  final int cid;
  final bool completed;
  final String tag;
  _E(this.cid, this.completed, this.tag);
}
