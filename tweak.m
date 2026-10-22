/*
 * WHS iOS Tweak — 精简版：只做「原图下载 + EXIF 原始信息提取」
 * 移植自 Android WHS (top.anjao2024.xp1whs) v3.0.9 小红书增强模块
 * 形态：注入小红书 iOS App 的 dylib（TrollFools 自签名注入 / 或 Theos deb 越狱安装）
 * 构建：clang 直接编 dylib（见 Makefile），或 Theos（见 WHSTweak.plist filter）
 *
 * 本版只保留用户要的功能：
 *   1) 原图下载 —— 浮窗 ↓ 按钮 / 双指长按，从界面抓取 CDN 原图 URL 下载到相册
 *      （同时解锁 App 原生保存开关，让 App 自带的长按保存也能用）
 *   2) EXIF 提取 —— 下载原图后解析 EXIF：相机品牌/型号、光圈、快门、ISO、焦距、镜头、拍摄时间
 *      弹窗展示，并自动复制到剪贴板，方便用户直接粘贴使用
 *
 * 设计原则：防御式 hook —— 类/方法不存在就跳过，绝不崩溃。
 * 小红书 iOS 自家类前缀：XY / XHS / Xhs
 *
 * 开关（NSUserDefaults，defaults 已写好）：
 *   whs_enabled  总开关         默认 YES
 *   whs_save     下载/保存解锁   默认 YES
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

#pragma mark - 配置与日志
static const BOOL kWHSVerbose = NO;
#define WHSLog(fmt, ...) do { if (kWHSVerbose) NSLog(@"[WHS] " fmt, ##__VA_ARGS__); } while (0)

static BOOL whs_flag(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

#pragma mark - 目标守卫（只对小红书生效）
static BOOL whs_isTarget(void) {
    static int cached = -1;
    if (cached >= 0) return cached != 0;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    cached = ([bid isEqualToString:@"com.xingin.discover"] || [exe isEqualToString:@"discover"]) ? 1 : 0;
    return cached != 0;
}

#pragma mark - 通用 IMP 助手（直接替换方法实现，缺方法自动跳过）
static BOOL whs_patchBool(Class cls, const char *selName, BOOL value) {
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    char rt[2] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    if (rt[0] != 'c' && rt[0] != 'B' && rt[0] != 'i') return NO;
    IMP imp = imp_implementationWithBlock(^BOOL(id self __attribute__((unused))) { return value; });
    method_setImplementation(m, imp);
    return YES;
}

static BOOL whs_dropSetter(Class cls, const char *selName) {
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP imp = imp_implementationWithBlock(^(id self __attribute__((unused)), id val __attribute__((unused))) {});
    method_setImplementation(m, imp);
    return YES;
}

static BOOL whs_patchVoid(Class cls, const char *selName) {
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    IMP imp = imp_implementationWithBlock(^(id self __attribute__((unused))) {});
    method_setImplementation(m, imp);
    return YES;
}

static void whs_exchangeClass(Class cls, SEL a, SEL b) {
    if (!cls) return;
    Method m1 = class_getClassMethod(cls, a);
    Method m2 = class_getClassMethod(cls, b);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

static void whs_exchangeInstance(Class cls, SEL a, SEL b) {
    if (!cls) return;
    Method m1 = class_getInstanceMethod(cls, a);
    Method m2 = class_getInstanceMethod(cls, b);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - 功能：下载/保存解锁（参考 HiveNoAds，已验证；让用户原生保存也能用）
static const char *kWHSKnownSaveClasses[] = {
    "XYPHMediaSaveConfig", "XYVFVideoDownloaderManager",
    "XYNoteFeedbackFloatingConfig", "NoteFeedbackFloatingConfig",
    "_TtC18XYNegativeFeedback12SaveProvider", "SaveProvider",
    "_TtC18XYNegativeFeedback18SaveCellController", "SaveCellController",
    "_TtC18XYNegativeFeedback16SaveImageService", "SaveImageService",
    "_TtC12XYNoteModule16ImageSaveService", "ImageSaveService",
    "_TtC12XYNoteModule19ImageSaveServiceAPM",
    "_TtC18XYNegativeFeedback24NotePaidDownloadProvider", "NotePaidDownloadProvider",
    "XHSAMiniToolSaveImageHandler", "XHSAMiniToolSaveFileHandler",
    "XHSAMiniToolAlbumSaver", "XHSAResourceDownloader",
    "XHSANativeShareViewController", "XHSAImagePickerController",
    NULL
};

static void whs_patchSaveClass(Class cls) {
    if (!cls) return;
    whs_patchBool(cls, "disableSave", NO);
    whs_patchBool(cls, "isDisableSave", NO);
    whs_patchBool(cls, "forbidCopy", NO);
    whs_patchBool(cls, "disableCopy", NO);
    whs_patchBool(cls, "disableCopyAction", NO);
    whs_patchBool(cls, "disableWatermark", YES);
    whs_patchBool(cls, "disableWatermarkWhenSavingAlbum", YES);
    whs_dropSetter(cls, "setDisableSave:");
    whs_dropSetter(cls, "setForbidCopy:");
    whs_dropSetter(cls, "setDisableCopy:");
    whs_patchBool(cls, "hitUserNoteDownloadSwitch", NO);
    whs_patchBool(cls, "userNoteDownloadSwitch", YES);
    whs_patchBool(cls, "isFlowDownloadSwitchOn", YES);
    whs_patchBool(cls, "notAllowDownloadMyVideos", NO);
    whs_patchBool(cls, "allowDownload", YES);
    whs_patchBool(cls, "shareImageSaveEnable", YES);
    whs_patchBool(cls, "shareVideoSaveEnable", YES);
    whs_patchBool(cls, "canSave", YES);
    whs_patchBool(cls, "canDownload", YES);
    whs_patchBool(cls, "isAvailable", YES);
    whs_patchBool(cls, "enable", YES);
    whs_patchBool(cls, "isEnabled", YES);
    whs_patchBool(cls, "isPaidImageNote", NO);
    whs_patchBool(cls, "isPaidDownload", NO);
    whs_patchBool(cls, "hasPaidDownload", NO);
    whs_patchBool(cls, "showPaidDownload", NO);
    whs_patchVoid(cls, "checkShowCloseNoteDownloadSwitchToast");
    whs_patchVoid(cls, "showCloseNoteDownloadSwitchToast");
    whs_patchVoid(cls, "showDownloadPermissionToast");
}

// 在 JSON 流里把下载开关字段强制为允许（仅改 NSNumber，避免破坏结构）
static void whs_patchDownloadObject(id obj) {
    if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSDictionary *snap = [obj copy];
        for (id k in snap) {
            NSString *ks = [k isKindOfClass:[NSString class]] ? k : [k description];
            id v = obj[k];
            if ([v isKindOfClass:[NSNumber class]] &&
                ([ks rangeOfString:@"disableSave" options:NSCaseInsensitiveSearch].length ||
                 [ks rangeOfString:@"prevent_download" options:NSCaseInsensitiveSearch].length ||
                 [ks rangeOfString:@"allow_download" options:NSCaseInsensitiveSearch].length ||
                 [ks rangeOfString:@"can_download" options:NSCaseInsensitiveSearch].length)) {
                obj[k] = @YES;
            }
            whs_patchDownloadObject(v);
        }
    } else if ([obj isKindOfClass:[NSMutableArray class]]) {
        for (id item in obj) whs_patchDownloadObject(item);
    }
}

@interface NSJSONSerialization (WHS)
+ (id)whs_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)err;
@end
@implementation NSJSONSerialization (WHS)
+ (id)whs_JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)err {
    id obj = [self whs_JSONObjectWithData:data options:opt error:err]; // 调用原始实现
    if ([obj isKindOfClass:[NSMutableDictionary class]] || [obj isKindOfClass:[NSMutableArray class]]) {
        @try { whs_patchDownloadObject(obj); } @catch (__unused NSException *e) {}
    }
    return obj;
}
@end

static void whs_installDownloadUnlock(void) {
    if (!whs_flag(@"whs_save", YES)) return;
    for (int i = 0; kWHSKnownSaveClasses[i]; i++) {
        Class c = NSClassFromString([NSString stringWithUTF8String:kWHSKnownSaveClasses[i]]);
        if (c) whs_patchSaveClass(c);
    }
    whs_exchangeClass(NSClassFromString(@"NSJSONSerialization"),
                      @selector(JSONObjectWithData:options:error:),
                      @selector(whs_JSONObjectWithData:options:error:));
    WHSLog(@"下载/保存解锁模块已装载");
}

#pragma mark - EXIF 提取（原图拍摄信息：手机/光圈/快门/ISO/焦距/镜头/时间）
static NSDictionary *whs_extractExif(NSData *data) {
    if (!data) return nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return nil;
    CFDictionaryRef meta = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!meta) return nil;
    NSDictionary *m = (__bridge_transfer NSDictionary *)meta;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *tiff = m[(__bridge NSString *)kCGImagePropertyTIFFDictionary];
    NSDictionary *exif = m[(__bridge NSString *)kCGImagePropertyExifDictionary];
    if (tiff) {
        if (tiff[(__bridge NSString *)kCGImagePropertyTIFFMake])   out[@"相机品牌"] = tiff[(__bridge NSString *)kCGImagePropertyTIFFMake];
        if (tiff[(__bridge NSString *)kCGImagePropertyTIFFModel])  out[@"相机型号"] = tiff[(__bridge NSString *)kCGImagePropertyTIFFModel];
        if (tiff[(__bridge NSString *)kCGImagePropertyTIFFSoftware]) out[@"软件"] = tiff[(__bridge NSString *)kCGImagePropertyTIFFSoftware];
    }
    if (exif) {
        if (exif[(__bridge NSString *)kCGImagePropertyExifFNumber])
            out[@"光圈"] = [NSString stringWithFormat:@"f/%@", exif[(__bridge NSString *)kCGImagePropertyExifFNumber]];
        if (exif[(__bridge NSString *)kCGImagePropertyExifExposureTime])
            out[@"快门"] = [NSString stringWithFormat:@"%@s", exif[(__bridge NSString *)kCGImagePropertyExifExposureTime]];
        id iso = exif[(__bridge NSString *)kCGImagePropertyExifISOSpeedRatings];
        if (iso) out[@"ISO"] = [iso isKindOfClass:[NSArray class]] ? [iso firstObject] : iso;
        if (exif[(__bridge NSString *)kCGImagePropertyExifFocalLength])
            out[@"焦距"] = [NSString stringWithFormat:@"%@mm", exif[(__bridge NSString *)kCGImagePropertyExifFocalLength]];
        if (exif[(__bridge NSString *)kCGImagePropertyExifLensModel]) out[@"镜头"] = exif[(__bridge NSString *)kCGImagePropertyExifLensModel];
        if (exif[(__bridge NSString *)kCGImagePropertyExifDateTimeOriginal]) out[@"拍摄时间"] = exif[(__bridge NSString *)kCGImagePropertyExifDateTimeOriginal];
    }
    return out.count ? out : nil;
}

static void whs_showExif(NSDictionary *exif) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableString *s = [NSMutableString string];
        for (NSString *k in exif) [s appendFormat:@"%@：%@\n", k, exif[k]];
        if (s.length) {
            [UIPasteboard generalPasteboard].string = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        UIWindow *w = UIApplication.sharedApplication.keyWindow;
        UIViewController *top = w.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"图片原始信息（已复制）"
                                                                  message:(s.length ? s : @"未检测到 EXIF（可能是平台处理后的图）")
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark - 浮窗 + 兜底抓取 / 下载（核心入口）
static UIButton *whs_floatingButton = nil;
static WHSSaveTrigger *whs_trigger = nil;

static BOOL whs_isMediaHost(NSString *s) {
    return [s containsString:@"xhscdn"] || [s containsString:@"xiaohongshu"] ||
           [s containsString:@"sns-img"] || [s containsString:@"sns-webpic"] ||
           [s containsString:@"sns-video"] || [s containsString:@"fe-video"] ||
           [s containsString:@"ci.xiaohongshu"];
}

static void whs_collectURLs(id obj, NSMutableSet *out, NSInteger depth) {
    if (!obj || depth > 6) return;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = obj;
        if (([s hasPrefix:@"http"] || [s hasPrefix:@"https"]) && whs_isMediaHost(s)) [out addObject:s];
        return;
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *s = [obj absoluteString];
        if (whs_isMediaHost(s) || [s hasPrefix:@"file:"]) [out addObject:s];
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) { for (id i in obj) whs_collectURLs(i, out, depth + 1); return; }
    if ([obj isKindOfClass:[NSDictionary class]]) { for (id i in [obj allValues]) whs_collectURLs(i, out, depth + 1); return; }
    if ([obj isKindOfClass:[AVURLAsset class]]) {
        NSString *s = [[obj URL] absoluteString];
        if (whs_isMediaHost(s) || [s hasPrefix:@"file:"]) [out addObject:s];
        return;
    }
    for (NSString *k in @[@"imageURL",@"imageUrl",@"url",@"currentImageURL",@"sd_imageURL",@"yy_imageURL",
                          @"videoURL",@"videoUrl",@"video_url",@"videoUrlString",@"master_url",@"originUrl",
                          @"videoSourceUrl",@"currentVideoURL",@"note",@"model",@"viewModel",@"media",
                          @"imageInfo",@"noteModel",@"videoModel",@"videoInfo",@"mediaModel",@"data",@"item",@"content"]) {
        @try { if ([obj respondsToSelector:NSSelectorFromString(k)]) whs_collectURLs([obj valueForKey:k], out, depth + 1); }
        @catch (__unused NSException *e) {}
    }
}

static void whs_collectFromView(UIView *root, NSMutableSet *out) {
    if (!root) return;
    UIView *v = root;
    for (int i = 0; i < 12 && v; i++, v = v.superview) whs_collectURLs(v, out, 0);
    for (UIView *sub in root.subviews) whs_collectFromView(sub, out);
}

static void whs_toast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = UIApplication.sharedApplication.keyWindow;
        if (!w) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = msg;
        l.textColor = UIColor.whiteColor;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        l.font = [UIFont systemFontOfSize:14];
        l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 8;
        l.layer.masksToBounds = YES;
        [l sizeToFit];
        CGFloat bw = l.bounds.size.width + 24;
        l.frame = CGRectMake((w.bounds.size.width - bw) / 2, w.bounds.size.height - 120, bw, 36);
        [w addSubview:l];
        [UIView animateWithDuration:0.3 delay:1.5 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL f) { [l removeFromSuperview]; }];
    });
}

static void whs_saveImageData(NSData *data, void (^done)(BOOL)) {
    UIImage *img = [UIImage imageWithData:data];
    if (!img) { done(NO); return; }
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus st) {
        if (st != PHAuthorizationStatusAuthorized) { done(NO); return; }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:img];
        } completionHandler:^(BOOL ok, NSError *e __attribute__((unused))) { done(ok); }];
    }];
}

static void whs_saveVideoURL(NSURL *url, void (^done)(BOOL)) {
    AVAsset *asset = [AVAsset assetWithURL:url];
    AVAssetExportSession *exp = [AVAssetExportSession exportSessionWithAsset:asset
                                                                presetName:AVAssetExportPresetPassthrough];
    if (!exp) {
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
        } completionHandler:^(BOOL ok, NSError *e __attribute__((unused))) { done(ok); }];
        return;
    }
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"whs_%@.mp4", [[NSUUID UUID] UUIDString]]];
    exp.outputURL = [NSURL fileURLWithPath:tmp];
    exp.outputFileType = AVFileTypeMPEG4;
    [exp exportAsynchronouslyWithCompletionHandler:^{
        BOOL ok = (exp.status == AVAssetExportSessionStatusCompleted);
        if (ok) {
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:tmp]];
            } completionHandler:^(BOOL ok2, NSError *e2 __attribute__((unused))) {
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
                done(ok2);
            }];
        } else { done(NO); }
    }];
}

// 下载一张图，并提取 EXIF 弹窗
static void whs_downloadImageWithExif(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"https://www.xiaohongshu.com" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    whs_toast(@"原图下载中…");
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp __attribute__((unused)), NSError *err) {
        if (!data || err) { whs_toast(@"下载失败"); return; }
        NSDictionary *exif = whs_extractExif(data);
        [whs_saveImageData(data, ^(BOOL ok) {
            if (ok) {
                whs_toast(@"已保存到相册");
                if (exif) whs_showExif(exif);
            } else {
                whs_toast(@"保存失败（请允许相册权限）");
            }
        }];
    }];
    [task resume];
}

static void whs_downloadVideo(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"https://www.xiaohongshu.com" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    whs_toast(@"视频下载中…");
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp __attribute__((unused)), NSError *err) {
        if (!data || err) { whs_toast(@"下载失败"); return; }
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"whs_%@.mp4", [[NSUUID UUID] UUIDString]]];
        [data writeToFile:tmp atomically:YES];
        whs_saveVideoURL([NSURL fileURLWithPath:tmp], ^(BOOL ok) { whs_toast(ok ? @"已保存到相册" : @"保存失败"); });
    }];
    [task resume];
}

// 浮窗触发：从当前界面抓取媒体，逐张下载原图并解析 EXIF
static void whs_tryDownloadCurrent(void) {
    UIWindow *w = UIApplication.sharedApplication.keyWindow;
    if (!w) { whs_toast(@"无窗口"); return; }
    NSMutableSet *urls = [NSMutableSet set];
    whs_collectFromView(w, urls);
    if (urls.count == 0) { whs_toast(@"未找到媒体，试试双指长按"); return; }
    BOOL anyVideo = NO;
    for (NSString *u in urls) if ([u containsString:@"video"] || [u containsString:@"mp4"]) { anyVideo = YES; break; }
    NSInteger n = 0;
    for (NSString *u in urls) {
        if (n++ > 8) break; // 一次最多抓 9 张，避免刷屏
        BOOL v = anyVideo && ([u containsString:@"video"] || [u containsString:@"mp4"]);
        if (v) whs_downloadVideo(u); else whs_downloadImageWithExif(u);
    }
    whs_toast([NSString stringWithFormat:@"找到 %lu 个媒体，开始下载原图", (unsigned long)urls.count]);
}

@interface WHSSaveTrigger : NSObject
- (void)onTap;
- (void)onGesture:(UILongPressGestureRecognizer *)g;
@end
@implementation WHSSaveTrigger
- (void)onTap { whs_tryDownloadCurrent(); }
- (void)onGesture:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) whs_tryDownloadCurrent();
}
@end

static void whs_installFloatingUI(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *w = UIApplication.sharedApplication.keyWindow;
        if (!w || whs_floatingButton) return;
        if (!whs_trigger) whs_trigger = [[WHSSaveTrigger alloc] init];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(w.bounds.size.width - 56, w.bounds.size.height - 130, 44, 44);
        [b setTitle:@"↓" forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:22];
        b.layer.cornerRadius = 22;
        b.layer.masksToBounds = YES;
        [b addTarget:whs_trigger action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:b];
        whs_floatingButton = b;
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:whs_trigger
                                                                                        action:@selector(onGesture:)];
        lp.numberOfTouchesRequired = 2;
        [w addGestureRecognizer:lp];
        WHSLog(@"下载浮窗已装载（点击或双指长按下载原图）");
    });
}

#pragma mark - 入口
__attribute__((constructor))
static void whs_entry(void) {
    WHSLog(@"WHS download tweak loaded");
    if (!whs_isTarget()) { WHSLog(@"非目标 App，退出"); return; }
    if (!whs_flag(@"whs_enabled", YES)) { WHSLog(@"总开关关闭"); return; }

    whs_installDownloadUnlock(); // 解锁原生保存 + JSON 下载开关
    whs_installFloatingUI();     // 浮窗 ↓ / 双指长按 → 抓 CDN 原图下载 + EXIF

    WHSLog(@"WHS 下载模块装载完成");
}
