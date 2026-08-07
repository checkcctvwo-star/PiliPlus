# Android 可移除 SD 卡访问调研

> 调研对象：PiliPlus (Flutter/Bilibili 客户端) 在用户把视频缓存目录选到可移除 microSD 卡
> （路径形如 `/storage/XXXX-XXXX/PiliPlus/download`，`XXXX-XXXX` 为卷 UUID）后，
> 出现「崩溃或清后台后再开应用，SD 卡上已缓存的视频从列表里消失」的 bug。
>
> 调研方法：仅对照高可信一手来源（Android 官方文档 developer.android.com / source.android.com、
> AOSP 源码 android.googlesource.com、Flutter/path_provider/permission_handler 官方仓库与 issue、
> Dart SDK 源码）。每个 claim 标注来源链接。所有结论可追溯到拥有该事实的来源。

---

## 摘要

| # | 子假设 | 结论 | 关键来源 |
|---|--------|------|----------|
| 1 | 路径稳定性：卷 UUID `/storage/XXXX-XXXX/` 在重启/重挂载后是否变化 | **REFUTED（不成立）** | AOSP `vold` `PublicVolume.cpp` 用文件系统 UUID 作稳定名；FAT 卷序列号格式化时写入、重挂载不变 |
| 2 | 挂载时序：冷启动时 SD 是否保证已挂载，有无竞态 | **CONFIRMED（成立）** | Android `Environment` 文档「重启后不要假设可移动介质已挂载」；`vold` 对「已在运行的应用」异步 bind-mount；真实复现 issue `tempo#275` |
| 3 | create() 掩盖：未挂载卷下 `create(recursive:true)` 是否静默成功 | **REFUTED（不成立）** | AOSP sepolicy：`/storage` 标 `storage_file`，应用仅 `r_dir_perms`（无 write/add_name），`mkdir` 被 SELinux 拒 `EACCES`；挂载点 stub 在 unmount 时被 `rmdir` |
| 4 | MANAGE_EXTERNAL_STORAGE 范围：是否覆盖可移除 SD | **REFUTED（不成立）** | 官方文档逐字：「Access to the root directory of … the SD card」；FUSE 层覆盖外置 sdcard |
| 5 | path_provider：`getExternalStorageDirectory()` 返回主模拟存储而非 SD | **CONFIRMED（成立）** | `path_provider_android` 源码映射 `getExternalFilesDir(null)`；官方文档「primary 外部存储」 |
| 额外 | MES 权限状态误报（granted=false） | **UNCLEAR（待定）** | `permission_handler#1169`：`manageExternalStorage.status` 报告 denied 实际已授予；单条未确认 issue |

**最可能根因**：子假设 **#2 挂载时序竞态**（设备重启后场景，证据最硬、有完全匹配的真实 issue）；
对「纯应用崩溃/清后台（未重启设备）」场景，#2 不适用，最可能触发点是 **`permission_handler#1169` 描述的 MES 状态误报导致 `granted=false`**（UNCLEAR）。
无论哪种触发，**#5 确认了回退目标**：`getExternalStorageDirectory()` 返回主模拟存储，回退后扫描内置自然找不到 SD 上的 `entry.json` —— 这正是「消失」的机制。

---

## 子假设详述

### 1. 路径稳定性 → REFUTED（不成立）

**结论**：`/storage/XXXX-XXXX/` 中的 `XXXX-XXXX` 是**文件系统 UUID**（FAT/exFAT 卷序列号），
在**设备重启 / 应用重启 / 同一张卡卸载重挂载**后保持稳定；仅在**重新格式化或更换物理卡**时才变化。
因此「存储的路径在重启后失效」不是本 bug 的根因。

**证据**：

- **vold 用文件系统 UUID 作为路径名（设计即为稳定名）。** AOSP `system/vold/model/PublicVolume.cpp`
  的 `doMount()` 中：
  ```cpp
  // Use UUID as stable name, if available
  std::string stableName = getId();
  if (!mFsUuid.empty()) {
      stableName = mFsUuid;
  }
  ...
  setPath(StringPrintf("/storage/%s", stableName.c_str()));
  ```
  注释「Use UUID as stable name」即作者对稳定性的断言。`/storage/XXXX-XXXX/` 目录名就是 `mFsUuid`。
  来源：[AOSP vold PublicVolume.cpp](https://android.googlesource.com/platform/system/vold/+/refs/heads/main/model/PublicVolume.cpp)
  （镜像佐证：[AOSPA](https://github.com/AOSPA/android_system_vold/blob/32f9582c1d3dd0edad4c87aa1d2e86063ed0c35c/model/PublicVolume.cpp)、
  [omnirom](https://github.com/omnirom/android_system_vold/blob/07ea2da8001f0acb410aa95b4f3fb5a54f251f1c/model/PublicVolume.cpp)）。

- **`mFsUuid` 从块设备上的文件系统元数据读取，非运行时生成。** `system/vold/Utils.cpp` 的
  `readMetadata()` 执行 `blkid -s TYPE -s UUID -s LABEL <devpath>`，把 `UUID` 行解析进 `mFsUuid`。
  `blkid` 读取的是盘上文件系统元数据。`readMetadata()` 在每次 `doMount()` 顶部调用，故每次挂载
  （每次开机/重挂载）都重新读取同一个盘上值。
  来源：[AOSP vold Utils.cpp](https://android.googlesource.com/platform/system/vold/+/refs/heads/main/Utils.cpp)。

- **公开 API `StorageVolume.getUuid()` 返回同一个文件系统 UUID。** `android/os/storage/StorageVolume.java`
  (android-35)：`public @Nullable String getUuid() { return mFsUuid; }`。Java 可见 UUID、vold `mFsUuid`、
  `/storage/` 路径分量三者同值。
  来源：[StorageVolume.java](https://github.com/Reginer/aosp-android-jar/blob/main/android-35/src/android/os/storage/StorageVolume.java)。

- **FAT 卷序列号格式化时写入一次、重挂载不变。** 「Volume serial number … determined by the real-time
  clock reading … when the volume is formatted」「formatting a volume typically changes the serial number,
  but relabeling does not」。32-bit 值正对应 `XXXX-XXXX`（4+4 hex）格式。
  来源：[Wikipedia: Volume serial number](https://en.wikipedia.org/wiki/Volume_serial_number)。

**各场景**：

| 场景 | UUID/路径稳定？ | 原因 |
|---|---|---|
| 设备重启 | 稳定 | 从同一盘上文件系统重读 UUID |
| 应用重启 | 稳定 | 卷仍挂载，路径不变 |
| 卸载重挂载（同一张卡） | 稳定 | 从同一盘上文件系统重读 UUID |
| 重新格式化 | **变化** | 新文件系统有新卷序列号 |
| 更换物理卡 | **变化** | 不同文件系统，不同 UUID |
| 卡尚未挂载时访问 | 路径有效但**不可访问** | 时序问题，非 UUID 变化（见子假设 2） |

**对 bug 的含义**：存储在 Hive 的 `/storage/1234-5678/PiliPlus/download` 不会因重启/应用重启而失效
（只要不重新格式化、不换卡）。路径字符串本身是好的；问题在启动时**检测可访问性/权限**，而非路径过期。

---

### 2. 挂载时序 → CONFIRMED（成立）

**结论**：冷启动（**设备重启后**）存在已知竞态——`vold` 异步挂载可移除 SD 卡，而应用代码可能先于
挂载完成就执行，使 `Directory(sdPath).existsSync()` 短暂返回 `false`，触发回退到内置存储，SD 缓存的
视频从列表「消失」。**纯应用崩溃/清后台（未重启设备）无此竞态**（卡仍挂载）。

**证据**：

- **可移动介质在开机时有「未就绪」窗口。** Android `Environment` 文档定义外部存储状态在开机时
  迁移 `MEDIA_UNMOUNTED → MEDIA_CHECKING → MEDIA_MOUNTED`，并明确警告：**「尤其对于可移动介质，
  永远不要假设它已挂载，尤其是刚开机后」**。各卷可处于不同状态——主卷已挂载而可移动卡仍未挂载。
  来源：[android.os.Environment](https://developer.android.com/reference/android/os/Environment)。

- **`ACTION_BOOT_COMPLETED` 不以保证可移动 SD 已挂载为前提。** Direct Boot 指南：`ACTION_BOOT_COMPLETED`
  在用户解锁后触发（凭据加密存储可用），但对可移动 SD 挂载只字未提。
  来源：[Direct Boot](https://developer.android.com/training/articles/direct-boot)。

- **`ACTION_MEDIA_MOUNTED` 是介质「就绪可读写」时才发的粘性广播**——它的存在意味着之前有「未就绪」
  区间。API 11 起不投递给 manifest receiver，应用必须运行时注册才能知道卡何时可用。
  来源：[Intent.ACTION_MEDIA_MOUNTED](https://developer.android.com/reference/android/content/Intent#ACTION_MEDIA_MOUNTED)。

- **vold 作用于「已在运行的应用」，证明应用进程先于/并行于挂载操作启动。** AOSP 存储文档：「当授予
  运行时权限时，`vold` 跳进已在运行的应用的挂载命名空间，把升级后的视图 bind-mount 进去」；每应用
  存储视图在「Zygote fork 时」bind-mount。
  来源：[source.android.com 存储](https://source.android.com/docs/core/storage)、
  [传统存储](https://source.android.com/docs/core/storage/traditional)。

- **真实复现——与本 bug 模式完全一致。** GitHub issue `CappielloAntonio/tempo#275`
  「[BUG] - External storage randomly changes to Internal」：音乐 app 的下载存储设置从外置翻回内置，
  报告者理论逐字就是本假设——「Maybe the SD card takes some time to be detected/mounted by Android.
  Tempo starts before the SD card is mounted, and since it does not know about a SD card, changes the
  storage to Internal.」另见 `OpenLauncherTeam/openlauncher#451`，维护者诊断为「SD 卡没足够快挂载」。
  来源：[tempo#275](https://github.com/CappielloAntonio/tempo/issues/275)、
  [openlauncher#451](https://github.com/OpenLauncherTeam/openlauncher/issues/451)。

**关键区分**：

- **设备重启 → 竞态存在。** `vold` 必须在开机期间异步重挂载可移动 SD。从最近任务恢复/开机后即启动的
  应用，其 `Activity onCreate` / Flutter 引擎初始化可能在卡挂载完成（状态仍 `MEDIA_UNMOUNTED`/`MEDIA_CHECKING`）
  且 vold 把卷 bind-mount 进应用命名空间之前执行。`existsSync()` 返回 false → 回退内置 → 视频消失。匹配报告的 bug。
- **应用被杀重启（未重启设备）→ 无竞态。** OS 未重启，`vold` 从未卸载卡；挂载与每应用运行时视图的
  bind-mount 持续。新进程从 Zygote fork 时继承当前挂载命名空间，其中 SD 已挂载可访问。`existsSync()` 返回 true。
  （例外：用户主动弹出、USB 大容量存储共享、物理拔卡会触发卸载——但那是另外的触发条件，非「OS 杀应用」。）

**对 bug 的含义**：若用户的「清后台/崩溃」伴随设备重启，#2 即根因（证据最硬）。
若纯属应用进程死亡（未重启设备），#2 不适用，需看 #额外（MES 状态误报）。

---

### 3. create() 掩盖效应 → REFUTED（不成立）

**结论**：当 SD 卷未挂载时，`Directory('/storage/XXXX-XXXX/...').create(recursive:true)` **不会**静默
成功——它会因 SELinux 拒绝抛 `FileSystemException`（`EACCES`），应用 `catch { accessible=false }` 正确执行。
不存在「在内置/overlay 上静默创建目录、让 accessible 错误为 true」的掩盖。`accessible` 的 false 是真阴性，
非假阳性。

**证据**：

- **挂载点 stub 在正常卸载时被删除，不残留。** AOSP `PublicVolume.cpp` 的 `doUnmount()` 显式
  `ForceUnmount(mountPath); rmdir(mountPath.c_str());`（`mountPath` 在 `/mnt/user/<userid>/` 下，是
  app 可见 `/storage/<UUID>` 的后端）。`bindMountForUser()` 创建 stub，`doUnmount` 是其逆操作。
  `VolumeBase::destroy()` 在先前状态为 `kMounted` 时调用 `unmount()->doUnmount()`，覆盖暴力拔卡场景。
  故正常弹出/暴力拔除后 `/storage/XXXX-XXXX/` 入口消失。
  来源：[PublicVolume.cpp](https://android.googlesource.com/platform/system/vold/+/refs/heads/main/model/PublicVolume.cpp)、
  [VolumeBase.cpp](https://android.googlesource.com/platform/system/vold/+/refs/heads/main/model/VolumeBase.cpp)。

- **应用无法在 `/storage/` 根下新建 `/storage/XXXX-XXXX` 来填补空缺（核心掩盖路径被堵）。** `/storage`
  及其下一切被 SELinux 标为 `storage_file`，`/mnt/user` 标为 `mnt_user_file`（AOSP sepolicy `file_contexts`）。
  appdomain 策略仅授予两者 `r_dir_perms`（`{ open getattr read search ioctl lock watch watch_reads }`），
  **无 `add_name`/`write`/`create`**（`app.te` 第 139-142 行；`r_dir_perms` 定义见 `global_macros`）。
  故应用的 `mkdir /storage/XXXX-XXXX` 命中真实 `/storage/` 目录（非 FUSE 挂载）被 SELinux 拒 `EACCES`。
  这对 legacy-storage 和 MANAGE_EXTERNAL_STORAGE 应用都成立——SELinux 独立于 FUSE 权限层。
  来源：[sepolicy file_contexts](https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/file_contexts)、
  [app.te](https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/app.te)。

- **不存在覆盖 `/storage/` 的单一 FUSE 挂载能把 mkdir 重路由到下层文件系统。** `FuseDaemon.cpp` 文档称
  每个 daemon 是「Single FUSE mount」，其 `fuse->path` 是特定卷路径（`/storage/emulated` 或
  `/storage/C58E-1702`）。每卷 FUSE/bind-mount 叠在 `/storage/` 之上；卷卸载后该挂载消失，留下普通
  `storage_file` 目录。故 `/storage/XXXX-XXXX` 处的 mkdir 永远到不了 FUSE daemon 的 `pf_mkdir`。
  来源：[FuseDaemon.cpp](https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main/jni/FuseDaemon.cpp)。

- **Dart 把失败作为抛出异常呈现，故 `accessible=true` 永不会设。** Dart VM（Android 用 `directory_linux.cc`）
  `Directory::Create` 调 `mkdirat()`，失败返回 `NewDartOSError()`，Dart 层包成 `FileSystemException._fromOSError`。
  API 契约：递归创建「所有不存在路径分量」，「若目录无法创建则抛异常」。递归走自顶向下，第一个缺失分量
  `/storage/XXXX-XXXX` 的 mkdir 返回 `EACCES`，`create()` 在 `accessible=true` 执行前抛出。
  来源：[dart directory_linux.cc](https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/bin/directory_linux.cc)、
  [Directory.create API](https://api.dart.dev/stable/dart-io/Directory/create.html)、
  [mkdir(2)](https://man7.org/linux/man-pages/man2/mkdir.2.html)。

- **开机竞态（卡在但未挂载）：结果相同。** stub 只在 `doMount()` 成功挂载后才创建；此前
  `/storage/XXXX-XXXX` 不存在，递归 create 试图在 `/storage/` 根 mkdir → SELinux `EACCES` → 抛 → `accessible=false`。
  来源：[app-specific 存储](https://developer.android.com/training/data-storage/app-specific)。

**对 bug 的含义**：`create 成功 ⇒ accessible=true` 的推断是可靠的，不是假阳性来源（只要应用真的 catch 了异常，
代码确实如此）。真正的风险相反——卡在但缺权限时 create 也会失败，但那是安全的假阴性，非本假设的危险假阳性。

---

### 4. MANAGE_EXTERNAL_STORAGE 范围 → REFUTED（不成立）

**结论**：`MANAGE_EXTERNAL_STORAGE`（MES）**明确覆盖可移除 SD 卡根目录**。官方文档逐字列出授予
「Access to the root directory of both the USB on-the-go (OTG) drive and the SD card」。无一手来源记录
OEM 权限范围分歧。「MES granted=true 但 SD 不可访问（因 MES 不覆盖可移除）」不成立。

**证据**：

- **MES 明确覆盖 SD 卡根（官方 API 契约）。** 「Manage all files on a storage device」页面逐字列出 MES 授予：
  *「Access to the root directory of both the USB on-the-go (OTG) drive and the SD card」*，另授予
  *「Read and write access to all files within shared storage」*。词中无「removable」但「SD card」被显式点名。
  来源：[manage-all-files](https://developer.android.com/training/data-storage/manage-all-files)。

- **可移动 SD 属于「external storage」，故 external-storage 权限覆盖它。** 数据存储概览：
  *「Removable volumes, such as an SD card, appear in the file system as part of external storage.」*
  MES 是「所有 external storage」权限，SD 是 external storage → 落入 MES，无需单独的可移动专用权限。
  来源：[data-storage](https://developer.android.com/training/data-storage)。

- **FUSE/MediaProvider 执法层覆盖外置 SD，故 MES 执法与卷无关。** AOSP 存储文档称存储设备被
  *「wrapped in a FUSE daemon」*，FUSE 设计为 *「allow apps to transparently use either the internal
  storage or an external sdcard」*。MES 经此同一 FUSE 层（MediaProvider 管理，呈现所有卷于 `/storage` 下，
  含可移动卷 `/storage/XXXX-XXXX/`）执法，对可移动卷与主卷一视同仁。
  来源：[source.android.com 存储](https://source.android.com/docs/core/storage)、
  [fuse-passthrough](https://source.android.com/docs/core/storage/fuse-passthrough)。

- **唯一有据的真实失败模式是挂载状态（非权限范围），且正是 `existsSync` 拦的。** app-specific 存储文档警告：
  *「The files in these directories aren't guaranteed to be accessible, such as when a removable SD card
  is taken out of the device」*，建议查 `Environment.getExternalStorageState()`（`MEDIA_MOUNTED`）。
  这是「卡被拔/未挂载」，非「granted=true 但权限不覆盖 SD」。bug 的 `accessible && granted` 闸门
  （`accessible`=`existsSync`）正是对此的正确防御。
  来源：[app-specific](https://developer.android.com/training/data-storage/app-specific)。

- **`permission_handler` 的 `manageExternalStorage` 是 1:1 映射，无可移除注意事项。** pub.dev README 确认
  `Permission.manageExternalStorage` 对应 Android `MANAGE_EXTERNAL_STORAGE`，打开系统设置意图（无对话框），
  `isGranted` 反映「所有文件访问」开关实际状态。README 未列任何「权限不覆盖可移除/SD」注意事项。
  来源：[pub.dev permission_handler](https://pub.dev/packages/permission_handler)。

**OEM 怪癖（华为 EMUI/HarmonyOS）**：调研期间所有 `developer.huawei.com` URL 持续返回 HTTP 502，无法引用
华为自有存储权限文档。华为 EMUI 与手机味 HarmonyOS（至 HarmonyOS 4）基于 AOSP，经标准 Android 框架
（MediaProvider/FUSE）运行 Android 应用，故同一 MES 执法适用。无一手来源记录「华为下 MES 已授予但可移除
SD 访问被额外权限阻断」。此为基于可访问 Android 平台来源的「未见证据」声明，非来自华为一手文档的确认。

**对 bug 的含义**：若 `Permission.manageExternalStorage.isGranted` 为 `true` 且路径 `existsSync()` 通过，
应用按文档 API 契约应能读写 `/storage/XXXX-XXXX/PiliPlus/download` 而无需 SAF。`accessible && granted`
闸门是健全的。问题不在 MES 范围。

---

### 5. Flutter path_provider → CONFIRMED（成立）

**结论**：Android 上 `getExternalStorageDirectory()` 返回**主模拟外部存储**的应用专属目录
（如 `/storage/emulated/0/Android/data/<package>/files`），映射 `Context.getExternalFilesDir(null)`，
**永不返回可移除 SD**。回退到它即扫描主存储，自然找不到 SD 上的 `entry.json` —— 这正是「消失」机制。

**证据**：

- **确切返回路径与 API 映射（现行源码）。** 当前 `path_provider_android` 实现
  `getExternalStoragePath()` 为 `_applicationContext.getExternalFilesDir(null)`，返回 `dir.absolutePath`，
  即 `/storage/emulated/0/Android/data/<package>/files`。公开 `getExternalStorageDirectory()` 仅调
  `_platform.getExternalStoragePath()`。
  来源：[path_provider_android_real.dart](https://github.com/flutter/packages/blob/main/packages/path_provider/path_provider_android/lib/src/path_provider_android_real.dart)、
  [path_provider.dart](https://github.com/flutter/packages/blob/main/packages/path_provider/path_provider/lib/path_provider.dart)。

- **单数 vs 复数 API 是决定性的。** 同一源文件：单数 `getExternalStoragePath()` 调 `getExternalFilesDir(null)`
  （单路径，仅主卷）；复数 `getExternalStoragePaths({type})` 调 `getExternalFilesDirs(directory)`（所有卷数组）。
  仅复数能返回可移除 SD（作为数组第 2+ 元素）。应用回退用单数，故只得主存储。
  来源：[path_provider_android_real.dart](https://github.com/flutter/packages/blob/main/packages/path_provider/path_provider_android/lib/src/path_provider_android_real.dart)。

- **Android 官方文档确认「仅主卷」。** `Context.getExternalFilesDir()` 「Returns the absolute path to the
  directory on the **primary** shared/external storage device.」复数 `ContextCompat.getExternalFilesDirs()`
  才覆盖额外卷：「the first element in the returned array is considered the primary external storage volume」，
  并警示可移动 SD 文件「aren't guaranteed to be accessible, such as when a removable SD card is taken out」。
  来源：[app-specific](https://developer.android.com/training/data-storage/app-specific)。

- **非已弃用的 `Environment.getExternalStorageDirectory()`。** path_provider 自 2019 年 7 月
  （commit `1850be0095`「[path_provider] Update to use getExternalFilesDir (#1811)」）改用 `getExternalFilesDir(null)`，
  不再用返回 `/storage/emulated/0` 的已弃用 `Environment.getExternalStorageDirectory()`。故 Android 11+
  单数 API 是 scoped-storage 友好且应用专属的，不返回共享存储根。
  来源：[commit 1850be0095](https://github.com/flutter/plugins/commit/1850be0095)。

- **GitHub issue 印证用户症状。** `flutter#40504`（open，2019-09）报告 `getExternalStorageDirectory()`
  返回 `/storage/emulated/0`（内置/主，非可移除），请求真正 SD/USB 支持；`flutter#77967`（open）
  「[path_provider] ignores SD card sometimes」报告复数 `getExternalStorageDirectories()` 有时省略
  `/storage/XXXX-XXXX/`。复数 API 才是触及 SD 卷的文档化路径。
  来源：[flutter#40504](https://github.com/flutter/flutter/issues/40504)、
  [flutter#77967](https://github.com/flutter/flutter/issues/77967)。

**对 bug 的含义**：若应用把 `entry.json` 缓存在 SD（如 `/storage/XXXX-XXXX/PiliPlus/download`），
回退用单数 `getExternalStorageDirectory()`，扫描目标变为 `/storage/emulated/0/Android/data/<pkg>/files/...`。
那是不同物理卷/路径，不含 SD 缓存的 entry —— 故列表「消失」。**这确认了「消失」机制（必要条件），
但其本身不是触发器**——触发器是 `granted=false` 或 `accessible=false`（见根因推断）。

---

## 额外发现的相关 issue

### permission_handler#1169 — MES 状态误报（**与「纯应用崩溃/清后台」场景最直接相关**）
- 仓库/URL：[Baseflow/flutter-permission-handler#1169](https://github.com/Baseflow/flutter-permission-handler/issues/1169)
- 状态/日期：Closed (needs more info) / 2023-09-27
- 摘要：`Permission.manageExternalStorage.status` 即使在用户经系统设置授予后**仍返回 `denied`**。
  报告者原话：「every time I check, it returns status denied even though I called settings and accepted
  before」「The permission only appears granted after returning from the settings page」。尽管状态 denied，
  文件操作仍能工作（OS 层权限实际已授予）。
- 根因：维护者未诊断，以 needs-info 关闭。底层 Android API `Environment.isExternalStorageManager()`
  可能报告陈旧/错误状态。
- 指向哪个子因：**MES 权限检测失败**。若启动时 `Permission.manageExternalStorage.isGranted` 返回 false
  （如此 issue 所述），PiliPlus 的 `_initDownPath()` 设 `granted=false`，跳过可访问性检查，
  `StoragePathResolver.resolve()` 返回内置回退，扫描无果。
- 可信度：单条报告、未由维护者确认（needs-info）。**作为根因属 UNCLEAR**，但它是唯一能解释
  「未重启设备、纯应用崩溃/清后台后消失」场景的候选。

### permission_handler#1481 — Android 13+ 切换 MES 状态崩溃
- URL：[permission_handler#1481](https://github.com/Baseflow/flutter-permission-handler/issues/1481)
- 状态/日期：Open / 2025-07-08
- 摘要：Android 13+ 多次切换「所有文件访问」开关后 `onActivityResult()` 抛 `NullPointerException`
  （陈旧 activity result 投递到 null 内部 map）。显示 MES 权限代码路径在 Android 13+ 有活跃 bug
  （虽此条是崩溃而非状态误报）。

### permission_handler#907 — Android 13 storage 永久拒绝误报
- URL：[permission_handler#907](https://github.com/Baseflow/flutter-permission-handler/issues/907)
- 状态/日期：Closed / 2022-09-05
- 摘要：Android 13 上 `Permission.storage.request()` 即使实际允许也返回 `permanentlyDenied`。
  证明 permission_handler 在 Android 13+ 误报存储权限状态的模式，间接支持 MES 误报可能。

### tempo#275 — 与本 bug 模式逐字一致（**最强真实佐证**）
- URL：[CappielloAntonio/tempo#275](https://github.com/CappielloAntonio/tempo/issues/275)
- 摘要：音乐 app 的下载存储设置从外置翻回内置。报告者理论即子假设 2 逐字复述——「Tempo starts before
  the SD card is mounted … changes the storage to Internal」。moto g7 plus / Android 12 LineageOS。
- 指向：**挂载竞态（#2）**。

### openlauncher#451 — SD 上应用快捷方式重启后消失
- URL：[openlauncher#451](https://github.com/OpenLauncherTeam/openlauncher/issues/451)
- 摘要：维护者诊断「SD 卡没足够快挂载，DatabaseHelper 删除找不到的应用」。
- 指向：**挂载竞态（#2）**。

### PiliPlus#2413 / PR#2465 — 本功能本身
- URL：[PiliPlus#2413](https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2413)（FR，open）、
  [PiliPlus PR#2465](https://github.com/bggRGjQaUbCoE/PiliPlus/pull/2465)（open）
- 摘要：SD 卡缓存路径支持的功能请求与实现 PR。PR 描述确认机制：「启动时扫描 downloadPath 读 entry.json
  重建列表（原有机制，路径无关）」「未选择则回退到原有 app 私有目录」。该 PR 的逻辑已在本地 main 分支
  `lib/main.dart` `_initDownPath()` 与 `lib/utils/storage_path_resolver.dart` 中确认（见附录）。

---

## 对根因的推断

### bug 触发的代码闸门（已在本地源码确认）

`lib/main.dart` `_initDownPath()`（Android 分支，第 75-99 行）：
```dart
final granted = await Permission.manageExternalStorage.isGranted;   // ①
bool accessible = false;
if (customDownPath != null && customDownPath.isNotEmpty && granted) { // ② granted=false 即跳过
  try {
    final dir = Directory(customDownPath);
    if (!dir.existsSync()) { await dir.create(recursive: true); }
    accessible = true;
  } catch (_) { accessible = false; }                                 // ③ existsSync/create 失败
}
downloadPath = StoragePathResolver.resolve(                          // ④
  customPath: customDownPath, permissionGranted: granted,
  customPathAccessible: accessible, fallbackPath: fallback,           // fallback = getExternalStorageDirectory() 内置
);
```
`StoragePathResolver.resolve()`（`lib/utils/storage_path_resolver.dart`）仅当 `permissionGranted && customPathAccessible`
才返回 `customPath`，否则 `fallbackPath`。列表由 `_readDownloadList()`（`lib/services/download/download_service.dart:70`）
扫描 `downloadPath` 下的 `entry.json` 重建，无持久数据库。

故「消失」当且仅当 ① `granted=false` **或** ③ `accessible=false`，使 ④ 回退到内置主模拟存储（#5 已确认回退目标
不含 SD 文件）。

### 各子假设对根因的贡献

- **#1 路径稳定性（REFUTED）**：不是根因。存储的 SD 路径字符串在重启/重挂载后有效（UUID 稳定）。
  无需「路径过期」假设。
- **#3 create() 掩盖（REFUTED）**：不是根因。`accessible` 不会因 create 静默成功而假阳性；
  它是真阴性。问题不是「accessible 错为 true」，而是「accessible/granted 错为 false」。
- **#4 MES 范围（REFUTED）**：不是根因。MES 覆盖 SD；若 `granted` 被正确检测为 true，SD 访问按契约可用。
- **#5 path_provider（CONFIRMED）**：是「消失」机制的**必要条件**，但非触发器。确认回退扫描内置主存储
  （不含 SD 的 entry.json），所以一旦回退发生，列表必然为空。无论触发器是什么，#5 解释了「为何回退 = 消失」。
- **#2 挂载竞态（CONFIRMED）**：是**设备重启场景**的根因（证据最硬）。重启后 vold 异步挂载 SD，
  应用早于挂载执行 → `existsSync()` false → `accessible=false` → 回退。有完全匹配的真实 issue（tempo#275）。
  **但仅适用于设备重启**；纯应用崩溃/清后台（未重启）卡仍挂载，#2 不触发。

### 最可能根因（按场景）

**场景 A — 伴随设备重启**（如用户重启手机、或 OEM 重启系统）：
> **根因 = 子假设 #2 挂载时序竞态（CONFIRMED）。**
> 重启后 SD 未及挂载时应用冷启动，`existsSync()` 返回 false，`accessible=false`，回退到内置主模拟存储（#5），
> 扫描无 `entry.json`，列表为空。证据：Android `Environment` 文档「重启后不要假设可移动介质已挂载」、
> vold 异步 bind-mount、tempo#275 逐字复述。这是唯一证据完全闭合的根因。

**场景 B — 纯应用崩溃/清后台（未重启设备）**：
> **#2 不适用**（卡仍挂载，`existsSync` 应为 true）。此时回退只能由 `granted=false` 触发。
> **最可能 = `permission_handler#1169` 描述的 MES 状态误报（UNCLEAR）。**
> 若 `Permission.manageExternalStorage.isGranted` 在全新进程启动时报 false（实际 OS 已授予），则 ② 被跳过、
  `accessible` 留 false、④ 回退。issue 报告者称「每次检查都返回 denied」「仅从设置页返回后才显示 granted」，
> 这与「崩溃/清后台后重开即消失」高度吻合（全新进程 = 状态被重读为 denied）。
> **但此为单条未确认 issue（closed needs-info），可信度 UNCLEAR**，需实测验证：在已授予 MES 的设备上
> 杀进程后冷启动，打印 `Permission.manageExternalStorage.isGranted` 的值。

### 为何其他子假设被排除

- 若根因是 #1（路径过期），则**任何**重启都必现且永久（路径永不恢复）；但用户报告「消失」可在重新操作后
  恢复，且 UUID 实际稳定——排除。
- 若根因是 #3（create 掩盖），则 `accessible` 会假阳性为 true、应用会继续用 SD 路径、文件不会消失——与症状相反，排除。
- 若根因是 #4（MES 不覆盖 SD），则即使 `granted=true` 且卡挂载，访问仍失败；但文档明确 MES 覆盖 SD——排除。

### 修复方向建议（非本调研范围，仅作推断顺带）

1. **启动时不立即回退**：检测到 SD 路径不可访问时，先监听 `ACTION_MEDIA_MOUNTED`（或轮询
   `Environment.getExternalStorageState()` == `MEDIA_MOUNTED`）等待卡挂载，超时后再回退。对应 #2。
2. **不单凭 `permission_handler.isGranted` 闸门**：用原生 `Environment.isExternalStorageManager()` 复核，
   或直接试访问 SD 路径（existsSync）——代码已对 accessible 做了 existsSync，但 ② 的 `&& granted` 让
   granted=false 时连试都不试。可改为「granted 或 accessible 任一为真则尝试」。对应 #额外/#1169。
3. **运行时动态解析 SD 路径**：用 `StorageManager.getStorageVolumes()` + `getUuid()`/`getDirectory()`
   动态解析，而非信任持久化路径字符串。对应 #1（虽 #1 已 REFUTED，但动态解析更健壮）。
4. **用复数 `getExternalStorageDirectories()`**：若需枚举含 SD 的所有卷。对应 #5。

---

## 附录：本地代码路径确认

以下文件/符号已在本地 `main` 分支确认存在（调研时读取）：

- `lib/main.dart:55` `_initDownPath()` — Android 分支（75-99 行）含 MES 权限检查 + existsSync/create + 回退逻辑，与 bug 描述一致。
- `lib/utils/storage_path_resolver.dart` `StoragePathResolver.resolve()` — 仅 `permissionGranted && customPathAccessible` 返回 customPath，否则 fallbackPath。
- `lib/main.dart:76` `getExternalStorageDirectory()` — 回退目标，#5 确认为主模拟存储。
- `lib/services/download/download_service.dart:70` `_readDownloadList()` — 扫描 `downloadPath` 下 `entry.json` 重建列表，无持久 DB。
- `lib/utils/storage_location.dart`、`lib/main.dart` 含 `manageExternalStorage` 引用。

---

## 一手来源总览

**Android 官方文档（developer.android.com / source.android.com）**
- https://developer.android.com/training/data-storage/manage-all-files （MES 范围，逐字「SD card」）
- https://developer.android.com/training/data-storage （SD 属 external storage）
- https://developer.android.com/training/data-storage/app-specific （主卷/复数卷/挂载状态警示）
- https://developer.android.com/reference/android/os/Environment （存储状态机、「重启后勿假设已挂载」）
- https://developer.android.com/training/articles/direct-boot （BOOT_COMPLETED 不保证 SD 挂载）
- https://developer.android.com/reference/android/content/Intent#ACTION_MEDIA_MOUNTED （就绪粘性广播）
- https://source.android.com/docs/core/storage （vold 作用于已运行应用、Zygote fork bind-mount）
- https://source.android.com/docs/core/storage/traditional （emulated FUSE/bind-mount）
- https://source.android.com/docs/core/storage/fuse-passthrough （FUSE 覆盖外置 sdcard）

**AOSP 源码（android.googlesource.com）**
- https://android.googlesource.com/platform/system/vold/+/refs/heads/main/model/PublicVolume.cpp （UUID 作稳定名；doMount/doUnmount/rmdir stub）
- https://android.googlesource.com/platform/system/vold/+/refs/heads/main/model/VolumeBase.cpp （destroy→unmount 状态机）
- https://android.googlesource.com/platform/system/vold/+/refs/heads/main/Utils.cpp （readMetadata/blkid 读 UUID）
- https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/file_contexts （/storage=storage_file）
- https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/app.te （appdomain 仅 r_dir_perms）
- https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main/jni/FuseDaemon.cpp （每卷单 FUSE 挂载）

**Flutter / path_provider / permission_handler**
- https://github.com/flutter/packages/blob/main/packages/path_provider/path_provider_android/lib/src/path_provider_android_real.dart （getExternalFilesDir(null) 单数 vs 复数）
- https://pub.dev/documentation/path_provider/latest/path_provider/getExternalStorageDirectory.html
- https://github.com/flutter/plugins/commit/1850be0095 （2019 改用 getExternalFilesDir）
- https://pub.dev/packages/permission_handler （MES 1:1 映射）

**Dart SDK / POSIX**
- https://raw.githubusercontent.com/dart-lang/sdk/main/runtime/bin/directory_linux.cc （mkdirat，失败返 OSError）
- https://api.dart.dev/stable/dart-io/Directory/create.html （递归创建，失败抛异常）
- https://man7.org/linux/man-pages/man2/mkdir.2.html （ENOENT/EACCES）

**相关 issue**
- https://github.com/CappielloAntonio/tempo/issues/275 （与本 bug 逐字一致，挂载竞态）
- https://github.com/OpenLauncherTeam/openlauncher/issues/451 （SD 挂载不够快）
- https://github.com/Baseflow/flutter-permission-handler/issues/1169 （MES 状态误报 denied）
- https://github.com/Baseflow/flutter-permission-handler/issues/1481 （Android 13+ MES 切换崩溃）
- https://github.com/Baseflow/flutter-permission-handler/issues/907 （Android 13 storage 永久拒绝误报）
- https://github.com/flutter/flutter/issues/40504 （path_provider 无可移除支持）
- https://github.com/flutter/flutter/issues/77967 （path_provider 有时忽略 SD）
- https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2413 （SD 缓存路径 FR）
- https://github.com/bggRGjQaUbCoE/PiliPlus/pull/2465 （SD 缓存路径实现 PR）

**其他**
- https://en.wikipedia.org/wiki/Volume_serial_number （FAT 卷序列号稳定性）
- https://github.com/Reginer/aosp-android-jar/blob/main/android-35/src/android/os/storage/StorageVolume.java （getUuid 返 mFsUuid）
