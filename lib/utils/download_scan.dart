/// 下载条目去重结果：按 isCompleted 分流后的去重列表。
class DedupedDownloads<T> {
  final List<T> completed;
  final List<T> incomplete;
  const DedupedDownloads(this.completed, this.incomplete);
}

/// 下载扫描条目去重的纯函数。
///
/// 把原始扫描条目按 cid 统一去重（首条优先），再按 isCompleted 分流到
/// completed / incomplete。当前实现里未完成条目直接 add 进 waitDownloadQueue、
/// 绕过去重，导致重扫或重复扫描（同目录在多路径中出现）时产生重复「正在缓存」条目。
/// 经此函数后，完成与未完成条目共用一次去重，消除重复。
abstract final class DownloadScan {
  static DedupedDownloads<T> dedup<T>(
    List<T> entries, {
    required int Function(T) cidOf,
    required bool Function(T) isCompletedOf,
  }) {
    final seen = <int>{};
    final completed = <T>[];
    final incomplete = <T>[];
    for (final e in entries) {
      if (seen.add(cidOf(e))) {
        (isCompletedOf(e) ? completed : incomplete).add(e);
      }
    }
    return DedupedDownloads(completed, incomplete);
  }
}
