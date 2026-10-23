/*
 * WHS iOS Tweak — 精简版：原图下载 + EXIF 提取
 * 注入小红书 iOS（com.xingin.discover）的 dylib（TrollFools 自签 / Theos deb）
 *
 * 实现要点（v0.3.0 重写）：
 *   1) 浮窗用「独立顶层 UIWindow（windowLevel=Alert+100，挂在 foregroundActive 的
 *      UIWindowScene 上）」，保证永远置顶、不被宿主 UI 遮挡、可拖动。
 *   2) 抓取真实媒体 URL 不靠猜模型属性，而是 hook SDWebImage 的图片加载入口
 *      （UIImageView + SDWebImageManager），App 加载哪张图就记录哪个真实 URL。
 *      打开大图时加载的就是高清/原图，自然抓到原图。
 *   3) 点浮窗 → 弹出「媒体列表」让你自己选下哪张（真正可控）；长按照片=快速存最近一张。
 *   4) 下载走原始 CDN 链接（去掉 imageView2 缩放参数取满分辨率）；XHS 水印是叠加层，
 *      原图本身无水印。
 *   5) EXIF：下载原图后用 ImageIO 解析；但 XHS 上传服务端普遍抹掉 EXIF，多数图没有。
 *
 * 防御式 hook：类/方法不存在就跳过，绝不崩溃。
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

#pragma mark - 目标守卫
static BOOL whs_isTarget(void) {
    static int cached = -1;
    if (cached >= 0) return cached != 0;
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
    cached = ([bid isEqualToString:@"com.xingin.discover"] || [exe isEqualToString:@"discover"]) ? 1 : 0;
    return cached != 0;
}

#pragma mark - 前向声明
static BOOL whs_isMediaHost(NSString *s);
static UIWindow *whs_activeWindow(void);
static UIViewController *whs_topController(void);
static void whs_presentPicker(void);

@interface WHSSaveTrigger : NSObject
+ (instancetype)shared;
- (void)onTap;
- (void)onLongPress:(UILongPressGestureRecognizer *)g;
- (void)onPan:(UIPanGestureRecognizer *)g;
@end

#pragma mark - 媒体 URL 捕获（核心：hook SDWebImage 加载层）
static NSMutableOrderedSet<NSString *> *whs_captured = nil;   // 最近捕获的 URL（最新的在前）
static dispatch_queue_t whs_captureQueue = NULL;

static void whs_captureURL(NSURL *url) {
    if (!url) return;
    NSString *s = url.absoluteString;
    if (![s hasPrefix:@"http"]) return;
    if (!whs_isMediaHost(s)) return;
    dispatch_async(whs_captureQueue, ^{
        if (!whs_captured) whs_captured = [NSMutableOrderedSet orderedSet];
        [whs_captured removeObject:s];
        [whs_captured insertObject:s atIndex:0];
        if (whs_captured.count > 80) {
            NSRange r = NSMakeRange(80, whs_captured.count - 80);
            [whs_captured removeObjectsInRange:r];
        }
    });
}

// 必须在 whs_isMediaHost 之前声明（下面用）
static BOOL whs_isMediaHost(NSString *s) {
    return [s containsString:@"xhscdn"] || [s containsString:@"xiaohongshu"] ||
           [s containsString:@"sns-img"] || [s containsString:@"sns-webpic"] ||
           [s containsString:@"sns-video"] || [s containsString:@"fe-video"] ||
           [s containsString:@"ci.xiaohongshu"];
}

// 去掉缩放/水印参数，尽量取满分辨率原图
static NSString *whs_originalURL(NSString *url) {
    if (!url) return url;
    // XHS CDN 常见缩放串：?imageView2/2/w/1080/.../format/webp 或 /wm 水印段
    NSRange q = [url rangeOfString:@"?"];
    if (q.location != NSNotFound) url = [url substringToIndex:q.location];
    // 去掉末尾的 /wm 或 /w/ 之类水印/缩放路径段（保守：只去掉明确的 /wm）
    url = [url stringByReplacingOccurrencesOfString:@"/wm" withString:@""];
    return url;
}

static BOOL whs_isVideoURL(NSString *s) {
    return [s containsString:@"video"] || [s.pathExtension.lowercaseString isEqualToString:@"mp4"] ||
           [s containsString:@"mp4"] || [s containsString:@"mov"];
}

#pragma mark - SDWebImage hook
@interface UIImageView (WHS)
- (void)whs_sd_setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)ph
                       options:(NSUInteger)options context:(id)context
                      progress:(id)progress completed:(id)completed;
@end
@implementation UIImageView (WHS)
- (void)whs_sd_setImageWithURL:(NSURL *)url placeholderImage:(UIImage *)ph
                       options:(NSUInteger)options context:(id)context
                      progress:(id)progress completed:(id)completed {
    whs_captureURL(url);
    [self whs_sd_setImageWithURL:url placeholderImage:ph options:options context:context
                        progress:progress completed:completed];
}
@end

@interface SDWebImageManager : NSObject
@end
@interface SDWebImageManager (WHS)
- (id)whs_downloadImageWithURL:(NSURL *)url options:(NSUInteger)options
                       context:(id)context progress:(id)progress completed:(id)completed;
@end
@implementation SDWebImageManager (WHS)
- (id)whs_downloadImageWithURL:(NSURL *)url options:(NSUInteger)options
                       context:(id)context progress:(id)progress completed:(id)completed {
    whs_captureURL(url);
    return [self whs_downloadImageWithURL:url options:options context:context
                                progress:progress completed:completed];
}
@end

static void whs_installImageHook(void) {
    Class iv = NSClassFromString(@"UIImageView");
    SEL a = @selector(sd_setImageWithURL:placeholderImage:options:context:progress:completed:);
    SEL b = @selector(whs_sd_setImageWithURL:placeholderImage:options:context:progress:completed:);
    if (iv && class_getInstanceMethod(iv, a) && class_getInstanceMethod(iv, b))
        method_exchangeImplementations(class_getInstanceMethod(iv, a), class_getInstanceMethod(iv, b));

    Class mgr = NSClassFromString(@"SDWebImageManager");
    SEL ma = @selector(downloadImageWithURL:options:context:progress:completed:);
    SEL mb = @selector(whs_downloadImageWithURL:options:context:progress:completed:);
    if (mgr && class_getInstanceMethod(mgr, ma) && class_getInstanceMethod(mgr, mb))
        method_exchangeImplementations(class_getInstanceMethod(mgr, ma), class_getInstanceMethod(mgr, mb));
    WHSLog(@"SDWebImage 图片 URL 捕获已装载");
}

#pragma mark - EXIF 提取
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
        if (tiff[(__bridge NSString *)kCGImagePropertyTIFFMake])    out[@"相机品牌"] = tiff[(__bridge NSString *)kCGImagePropertyTIFFMake];
        if (tiff[(__bridge NSString *)kCGImagePropertyTIFFModel])   out[@"相机型号"] = tiff[(__bridge NSString *)kCGImagePropertyTIFFModel];
        if (tiff[(__bridge NSString *)kCGImagePropertyTIFFSoftware]) out[@"软件"]   = tiff[(__bridge NSString *)kCGImagePropertyTIFFSoftware];
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
        if (s.length) [UIPasteboard generalPasteboard].string =
            [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        UIViewController *top = whs_topController();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"图片原始信息（已复制）"
                                                                  message:(s.length ? s : @"未检测到 EXIF（多为平台上传时已抹除）")
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        if (top) [top presentViewController:a animated:YES completion:nil];
    });
}

#pragma mark - 下载 / 保存
static void whs_toast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = whs_activeWindow();
        if (!w) return;
        UILabel *l = [[UILabel alloc] init];
        l.text = msg; l.textColor = UIColor.whiteColor;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.font = [UIFont systemFontOfSize:14];
        l.textAlignment = NSTextAlignmentCenter;
        l.layer.cornerRadius = 8; l.layer.masksToBounds = YES;
        l.numberOfLines = 0;
        CGSize sz = [l.text boundingRectWithSize:CGSizeMake(260, 200)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName:l.font} context:nil].size;
        CGFloat bw = sz.width + 28, bh = sz.height + 20;
        l.frame = CGRectMake((w.bounds.size.width - bw) / 2, w.bounds.size.height - 130, bw, bh);
        [w addSubview:l];
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ l.alpha = 0; }
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
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil]; done(ok2);
            }];
        } else { done(NO); }
    }];
}

static void whs_downloadImage(NSString *urlString) {
    NSString *u = whs_originalURL(urlString);
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"https://www.xiaohongshu.com" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" forHTTPHeaderField:@"User-Agent"];
    whs_toast(@"原图下载中…");
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp __attribute__((unused)), NSError *err) {
        if (!data || err) { whs_toast(@"下载失败"); return; }
        NSDictionary *exif = whs_extractExif(data);
        whs_saveImageData(data, ^(BOOL ok) {
            if (ok) { whs_toast(@"已保存到相册"); if (exif) whs_showExif(exif); }
            else whs_toast(@"保存失败（请允许相册权限）");
        });
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

#pragma mark - 窗口 / 顶层控制器辅助
static UIWindow *whs_activeWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)s;
                for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
                return ws.windows.firstObject;
            }
        }
    }
    return UIApplication.sharedApplication.keyWindow;
}

static UIViewController *whs_topController(void) {
    UIViewController *top = whs_activeWindow().rootViewController;
    while (top) {
        if (top.presentedViewController) { top = top.presentedViewController; continue; }
        if ([top isKindOfClass:[UINavigationController class]])
            top = ((UINavigationController *)top).visibleViewController;
        else if ([top isKindOfClass:[UITabBarController class]])
            top = ((UITabBarController *)top).selectedViewController;
        else break;
    }
    return top;
}

#pragma mark - 浮窗（独立顶层 window，可拖动，点开媒体列表）
static UIWindow *whs_floatWindow = nil;
static UIButton *whs_floatButton = nil;

static void whs_presentPicker(void) {
    __block NSArray<NSString *> *list = nil;
    dispatch_sync(whs_captureQueue, ^{ list = whs_captured ? [whs_captured.array copy] : @[]; });
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSString *u in list) {
        [picked addObject:u];
        if (picked.count >= 15) break;
    }
    if (picked.count == 0) { whs_toast(@"还没抓到媒体，先进笔记打开图片/视频"); return; }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择要保存的媒体"
                                                                  message:[NSString stringWithFormat:@"已抓取 %lu 个（最多显示 15）", (unsigned long)picked.count]
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSInteger idx = 0;
    for (NSString *u in picked) {
        BOOL vid = whs_isVideoURL(u);
        NSString *title = [NSString stringWithFormat:@"%@ #%ld  %@", vid ? @"🎬视频" : @"🖼图片",
                           (long)(idx + 1), [u.pathExtension.uppercaseString ?: @"?" stringByAppendingString:@""]];
        if (u.pathExtension.length == 0) title = [NSString stringWithFormat:@"%@ #%ld", vid ? @"🎬视频" : @"🖼图片", (long)(idx + 1)];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a __attribute__((unused))) {
            if (vid) whs_downloadVideo(u); else whs_downloadImage(u);
        }]];
        idx++;
    }
    // 一次性下载全部图片
    [sheet addAction:[UIAlertAction actionWithTitle:@"⬇ 下载全部图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a __attribute__((unused))) {
        NSInteger n = 0;
        for (NSString *u in picked) {
            if (whs_isVideoURL(u)) continue;
            whs_downloadImage(u);
            if (++n > 9) break;
        }
        whs_toast([NSString stringWithFormat:@"已发起 %ld 张图片下载", (long)n]);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *top = whs_topController();
    if (top) [top presentViewController:sheet animated:YES completion:nil];
}

static void whs_installFloatingUI(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (whs_floatWindow) return;
        UIWindowScene *scene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                    scene = (UIWindowScene *)s; break;
                }
            }
        }
        UIWindow *w = nil;
        if (@available(iOS 13.0, *)) { if (scene) w = [[UIWindow alloc] initWithWindowScene:scene]; }
        if (!w) w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.hidden = NO;
        w.userInteractionEnabled = YES;

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        CGFloat sz = 56;
        b.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - sz - 16,
                             UIScreen.mainScreen.bounds.size.height - sz - 120, sz, sz);
        [b setTitle:@"⬇" forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:26];
        b.backgroundColor = [UIColor colorWithRed:0.95 green:0.23 blue:0.35 alpha:0.92];
        b.layer.cornerRadius = sz / 2;
        b.layer.masksToBounds = YES;
        b.layer.shadowColor = [UIColor blackColor].CGColor;
        b.layer.shadowOpacity = 0.4; b.layer.shadowRadius = 6;
        [b addTarget:[WHSSaveTrigger shared] action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:[WHSSaveTrigger shared]
                                                                                        action:@selector(onLongPress:)];
        [b addGestureRecognizer:lp];
        // 拖动
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[WHSSaveTrigger shared]
                                                                             action:@selector(onPan:)];
        [b addGestureRecognizer:pan];

        [w addSubview:b];
        whs_floatWindow = w;
        whs_floatButton = b;
        WHSLog(@"浮窗已装载（点开媒体列表 / 长按存最近一张 / 可拖动）");
    });
}

#pragma mark - 触发逻辑
@implementation WHSSaveTrigger
+ (instancetype)shared { static WHSSaveTrigger *s; static dispatch_once_t t; dispatch_once(&t, ^{ s = [WHSSaveTrigger new]; }); return s; }
- (void)onTap { whs_presentPicker(); }
- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    __block NSString *last = nil;
    dispatch_sync(whs_captureQueue, ^{ last = whs_captured.firstObject; });
    if (!last) { whs_toast(@"还没有抓到媒体"); return; }
    if (whs_isVideoURL(last)) whs_downloadVideo(last); else whs_downloadImage(last);
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:g.view.superview];
        CGPoint c = g.view.center;
        c.x += t.x; c.y += t.y;
        CGFloat W = UIScreen.mainScreen.bounds.size.width, H = UIScreen.mainScreen.bounds.size.height;
        c.x = MAX(30, MIN(W - 30, c.x)); c.y = MAX(60, MIN(H - 30, c.y));
        g.view.center = c;
        [g setTranslation:CGPointZero inView:g.view.superview];
    }
}
@end

#pragma mark - 入口
__attribute__((constructor))
static void whs_entry(void) {
    WHSLog(@"WHS download tweak loaded");
    if (!whs_isTarget()) { WHSLog(@"非目标 App，退出"); return; }
    if (!whs_flag(@"whs_enabled", YES)) { WHSLog(@"总开关关闭"); return; }
    whs_captureQueue = dispatch_queue_create("whs.capture", DISPATCH_QUEUE_SERIAL);
    whs_installImageHook();     // 抓真实媒体 URL
    whs_installFloatingUI();    // 浮窗 + 媒体列表（可控）
    WHSLog(@"WHS 下载模块装载完成");
}
