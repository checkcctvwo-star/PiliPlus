import 'package:PiliPlus/utils/migration_decision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('无旧内容不迁移', () {
    final d = MigrationDecision.decide(
      oldPath: '/old',
      newPath: '/new',
      hasExistingDownloads: false,
      userWantsMigrate: true,
    );
    expect(d.action, MigrationAction.none);
  });

  test('用户选搬 -> migrate', () {
    final d = MigrationDecision.decide(
      oldPath: '/old',
      newPath: '/new',
      hasExistingDownloads: true,
      userWantsMigrate: true,
    );
    expect(d.action, MigrationAction.migrate);
    expect(d.oldPath, '/old');
  });

  test('用户不搬 -> keepAsExtraScan', () {
    final d = MigrationDecision.decide(
      oldPath: '/old',
      newPath: '/new',
      hasExistingDownloads: true,
      userWantsMigrate: false,
    );
    expect(d.action, MigrationAction.keepAsExtraScan);
  });

  test('新旧同路径不迁移', () {
    final d = MigrationDecision.decide(
      oldPath: '/same',
      newPath: '/same',
      hasExistingDownloads: true,
      userWantsMigrate: true,
    );
    expect(d.action, MigrationAction.none);
  });
}
