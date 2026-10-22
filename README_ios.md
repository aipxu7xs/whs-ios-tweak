# WHS iOS Tweak 工程说明

移植自 Android 模块 `top.anjao2024.xp1whs` v3.0.9（LSPosed 模块）。
iOS 端形态：**注入小红书 iOS App 的 dylib**（自签名注入）或 **deb**（越狱安装）。

## 关键前提
- iOS 小红书是独立二进制（ObjC/Swift），**与 Android 的 `com.xingin.*` 类毫无关系**。
- 因此 Android 逆向里最有价值的"hook 目标类"在 iOS 全部作废，必须单独逆 iOS 版。
- 步骤：拿到**脱壳 IPA** → class-dump / LIEF 抽 ObjC 类方法 → 定位 hook 点 → 写 swizzle。

## 工作流
1. 把脱壳后的 IPA 放到本目录，命名 `Xiaohongshu.ipa`（或解出的主 Mach-O）。
2. 跑抽取：
   ```
   ../venv/Scripts/python dump_objc.py Xiaohongshu.ipa --kw feed,note,download,ad,comment,tab,update,profile
   ```
   产出 `extracted/objc_all.txt`（全量）和 `extracted/objc_match.txt`（关键词命中）。
3. 在 `objc_match.txt` 里找对应 Android 功能的 iOS 类/方法，回填到 `tweak.m` 的 TODO。
4. 编译 dylib：
   - Theos：`make`；
   - 或直接 clang：`make SDK=/path/to/iPhoneOS.sdk`（见 Makefile）；
5. 注入/安装：
   - 无越狱：用 insert_dylib / optool 把 `tweak.dylib` 注入自签名 IPA，再重签侧载；
   - 越狱：按 `control` 打 deb，Cydia/ElleKit 加载。

## 当前范围（v0.2.0，按用户要求精简）
> **只做下载功能**：原图下载 + EXIF 原始信息提取。广告净化 / 双击点赞 / UI 增强 / 更新拦截 / 书签 / 鉴权 等 WHS 其它功能**已按用户要求全部移除**，不在本 dylib 内。

### 已实现
1. **原图下载**（核心）
   - 浮窗 `↓` 按钮（点击）或 **双指长按**屏幕 → 从当前界面视图树抓取小红书 CDN 原图/视频 URL（`xhscdn`/`sns-img`/`sns-video` 等），逐张下载到相册。
   - 同时解锁 App 原生保存开关（`disableSave`/`allowDownload` 等 IMP patch + `NSJSONSerialization` 下载字段改写），让 App 自带的长按保存也能用。
   - 参考 blueskycrb/HiveNoAds 的 `Xiaohongshu.dylib`（已验证方案）。
2. **EXIF 原始信息提取**（用户额外要求）
   - 下载原图后用 ImageIO 解析 EXIF：相机品牌 / 相机型号 / 软件 / 光圈 / 快门 / ISO / 焦距 / 镜头 / 拍摄时间。
   - 弹窗展示，并**自动复制到剪贴板**，方便直接粘贴。
   - 注：若小红书下发的不是原图（已转码/去 EXIF 的缩略图），则弹窗提示"未检测到 EXIF"。要拿原始拍摄信息需抓到"原图/大图" CDN（本工具优先 `originUrl`/`master_url` 等大图链接）。

### iOS 候选类（仅下载相关，已从脱壳 IPA 抽取，前缀 XY/XHS/Xhs）
- 保存/下载开关：`XYPHMediaSaveConfig`、`SaveProvider`/`_TtC18XYNegativeFeedback12SaveProvider`、`ImageSaveService`/`_TtC12XYNoteModule16ImageSaveService`、`NotePaidDownloadProvider`、`XHSAMiniToolSaveImageHandler`、`XHSAMiniToolSaveFileHandler`、`XHSAMiniToolAlbumSaver`、`XHSAResourceDownloader`、`XHSANativeShareViewController`
- 浮窗/兜底抓取不依赖具体类，纯运行时 KVC 扫视图树（`imageURL`/`videoURL`/`master_url`/`originUrl` 等）。

### 开关（NSUserDefaults，defaults 已写好）
- `whs_enabled` 总开关（默认 YES）
- `whs_save` 下载/保存解锁（默认 YES）

### 构建 / 注入
- 编译：`make SDK=/path/to/iPhoneOS.sdk` → 产出 `tweak.dylib`（已补 `-framework Photos/AVFoundation/ImageIO`）。
- 注入：TrollFools 选小红书 → 注入 `tweak.dylib` → 杀掉重开；或 Theos 打 deb（`WHSTweak.plist` filter `com.xingin.discover`）。
- 使用：打开笔记 → 点 `↓` 或双指长按 → 原图存相册 + EXIF 弹窗（已复制）。

## Android WHS 功能 → iOS 映射（历史参考，本版仅取"下载"）
> iOS 类名来自脱壳 IPA 主二进制 `discover` 的 ObjC 类抽取（手写 Mach-O 解析，前缀 XY/XHS/Xhs）。

| Android 功能 | 本版状态 | iOS 候选类（仅参考） |
|---|---|---|
| 媒体下载/保存 | ✅ 已实现（原图下载+EXIF） | `XHSAMiniToolSaveImageHandler`、`XHSAMiniToolAlbumSaver`、`XHSAResourceDownloader`、`SaveProvider`、`ImageSaveService` |
| 广告净化 | ❌ 用户要求不做 | `XYAdsBusiness`、`XYAdsSplash` 等 |
| 双击点赞拦截 | ❌ 用户要求不做 | `XYNoteLikeButton` 等 |
| 界面增强 / 更新拦截 / 书签 / 鉴权 | ❌ 用户要求不做 | `XHSATabBarController`、`XHSAUpdateService`、`XHSARouter` 等 |

## GitHub 参考项目（已实现，可直接借鉴 / 当蓝图）

> 用户原话："这个应该在 github 上有类似的参考"。已检索并核实以下仓库，结论：**存在可直接对标的小红书 iOS dylib 方案**，且交付格式（TrollFools 注入的 .dylib / 越狱 .deb）与用户的诉求完全一致。

### 1. blueskycrb/HiveNoAds（★ 最相关，强烈建议当模板）
- 仓库：https://github.com/blueskycrb/HiveNoAds
- 形态：为 **TrollFools** 注入产出的**每 App 一个 .dylib**（如 `Fengchao.dylib`/`Xiaohongshu.dylib`/`Douyin.dylib`），**不依赖 MobileSubstrate / 不要求越狱** —— 与用户"自签名注入 dylib"诉求完全吻合。
- 已内置 **`Xiaohongshu.dylib`（小红书图片+视频保存解锁）**：分析版本 `com.xingin.discover` / `discover` 9.38.1。这正是 WHS 的"媒体下载/保存"功能，且已经是**已验证可行**的实现，可大幅降低我们的逆向成本。
- 核心做法（已从源码核实）：
  - **目标守卫** `XHSIsTarget()`：只认 `com.xingin.discover` / `discover`，避免误注入。
  - **白名单机制**：只对已知类做 hook（`XYPHMediaSaveConfig`、`_TtC18XYNegativeFeedback12SaveProvider`、`SaveProvider`、`_TtC12XYNoteModule16ImageSaveService`、`ImageSaveService`、`NotePaidDownloadProvider` 等），**不做全量 `objc_copyClassList` 扫描、不全局 swizzle `UIView`** —— 启动性能接近原生（旧版因全量扫描+全局 didMoveToWindow 导致启动慢，已优化）。
  - **保存解锁**：`XHSPatchKnownClass` 用 `method_setImplementation` 把 `disableSave/forbidCopy/disableWatermark/allowDownload/shareImageSaveEnable/...` 强制改 BOOL，并 patch setter 丢弃；配合 `NSJSONSerialization` 热路径钩子改写 `prevent_download` 等 JSON 字段、以及 `NSUserDefaults` 隐私下载键钩子。
  - **兜底抓取**：浮窗 ↓ + 双指长按，从视图树 KVC 抓 `imageURL/videoURL/master_url` 等，校验 `xhscdn/xiaohongshu/sns-video/...` 主机头；图片走 `PHAssetChangeRequest`，视频走 `AVAssetExportSession` 转标准 mp4（规避 PHPhotos 3302）。
- **广告净化架构**（同仓其它 App 的 dylib，如 `Fengchao.dylib`/`QQMusic.dylib`）正是 WHS"广告净化"的现成蓝图：白名单广告类 + 仅给广告 View 子类装 `didMoveToWindow`/`setHidden`，而非全局 UIView swizzle。
- 仓库结构 = `apps/<App>/<App>.m` 一键产出 `dist/<App>.dylib`，GitHub Actions 自动编 arm64。我们可照搬：`apps/WHSTweak/WHSTweak.m` → `WHSTweak.dylib`。
- 另外还提供 **`.deb` 路线**（RootHide/Bootstrap，`iphoneos-arm64e`，无 `/var/jb`）——对应"越狱 .deb"诉求。

### 2. NEORUAA/XHS_Downloader_iOS（下载逻辑参考，但形态不同）
- 仓库：https://github.com/NEORUAA/XHS_Downloader_iOS （AGPL-3.0）
- 形态：**独立 iOS App**（非注入 tweak），从分享链接解析 `xiaohongshu.com/explore` / `xhslink.com` 提取原图/视频 CDN 地址。
- 价值：CDN URL 解析、链接类型识别的参考；但它是"外挂 App"不是"注入 dylib"，与我们的注入路线不同，仅作下载解析逻辑借鉴。

### 3. huami1314/XHSTranslator（Theos/Logos 越狱 tweak 范本）
- 仓库：https://github.com/huami1314/XHSTranslator （MIT）
- 形态：**Theos + Logos** 越狱 tweak（ObjC 69.7% + Logos 24.9%），有 `Makefile`/`control`/`XHSTranslator.xm`/`XHSTranslator.plist`（filter 指定小红书）。
- 价值：证明小红书 iOS 越狱 tweak 在 GitHub 上真实存在；提供 **Logos `%hook` 写法 + `.plist` filter + deb 打包** 的完整可编译范本，正好补我们 `.deb` 路线的模板。

### 4. 配套工具链参考
- **TrollFools**（Lessica/TrollFools）：无越狱注入 dylib 的工具本体（用户路线 A 的运行载体）。
- **Theos / HookKit / MonkeyDev / TikTok-Tweaks**：Logos `%hook` 语法、HookKit 统一 ElleKit/substrate/fishhook、MonkeyDev 非越狱开发、TikTok-Tweaks（MonkeyDev 下载无水印+跳广告）等参考范式。

### 借鉴结论（对 WHS 移植的直接意义）
- **下载/保存**：直接参考 HiveNoAds 的 `Xiaohongshu.m`（白名单 + `disableSave` 等 IMP patch + JSON/UD 钩子 + 浮窗/双指长按兜底），这是已验证方案，我们不必从零逆。
- **广告净化**：参考 HiveNoAds 的广告 dylib 架构（白名单广告类 + 定向 `didMoveToWindow`/`setHidden`），不要走旧版全局 UIView swizzle。
- **更新拦截 / UI 增强 / 书签 / 双击点赞**：仍按我们抽出的 iOS 候选类（`XHSAUpdateService`、`XHSATabBarController`、`XHSARouter`、`XYNoteLikeButton` 等）做 class→method 映射后写 swizzle（HiveNoAds 未覆盖这些）。
- **交付**：优先产出 TrollFools `.dylib`（贴合用户"自签名注入"），同时保留 `.deb`（Theos，仿 XHSTranslator）路线。

## 文件
- `dump_objc.py` — 手写 Mach-O 解析抽取 iOS ObjC 类/方法（LIEF 1.0.0 在该二进制取不到 ObjC 元数据，已弃用 LIEF，改用纯 Python 抠 `__objc_classname`/`__objc_methname` 段）
- `tweak.m` — dylib 源码骨架（功能 stub + swizzle 助手 + iOS 候选类）
- `Makefile` — clang 编 dylib
- `control` — deb 控制文件
