/*
 * SquidToPullOverX.mm — 翻译层 v3 (文件日志版)
 *
 * 目标: 让 SquidGesture 原生"在PullOver打开"手势驱动 PullOver X 开小窗。
 *   根因(已验证): SquidGesture 直接调 PullOverWindow.sharedWindow.controller.pinAppWithBundleId:,
 *   但 PullOver X 窗口需 initWithWindowScene: 初始化后才有用; 未初始化则静默失败。
 *
 * 本版核心改进: 所有日志写入 /var/mobile/Documents/SQBridge.log (Filza 可打开),
 *   解决"看不到 SpringBoard 日志"的堵点, 拿决定性运行数据。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <time.h>

static NSString *SQBridgeLogPath(void) {
    return @"/var/mobile/Documents/SQBridge.log";
}

void SQBridgeWrite(NSString *msg) {
    // 追加写文件
    NSString *line = [msg stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:SQBridgeLogPath()];
    if (!fh) {
        [line writeToFile:SQBridgeLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        @catch(NSException *e) {}
    }
    // 同时给系统日志
    NSLog(@"[SQBridge] %@", msg);
}

static void SQBridgeLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // 加时间戳
    time_t now = time(NULL);
    struct tm tm; localtime_r(&now, &tm);
    char tbuf[32]; strftime(tbuf, sizeof(tbuf), "%H:%M:%S", &tm);
    SQBridgeWrite([NSString stringWithFormat:@"%s %@", tbuf, msg]);
}

/* 确保 PullOver X 窗口已初始化并绑定主 scene */
static id SQBridgeEnsurePullOverWindow(void) {
    Class wc = NSClassFromString(@"PullOverWindow");
    if (!wc) { SQBridgeLog(@"PullOverWindow class NOT found"); return nil; }
    id (*getWindow)(id,SEL) = (id(*)(id,SEL))objc_msgSend;
    id window = getWindow(wc, sel_registerName("sharedWindow"));
    if (window) {
        id ctrl = [window valueForKey:@"controller"];
        SQBridgeLog(@"sharedWindow OK -> %@ controller=%@", window, ctrl);
        if (!ctrl) {
            // controller 未建, 尝试触发窗口 build
        }
        return [window valueForKey:@"controller"] ?: (id)nil;
    }
    SQBridgeLog(@"sharedWindow nil; attempting init");
    id app = ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"UIApplication"), sel_registerName("sharedApplication"));
    id keyWin = app ? ((id(*)(id,SEL))objc_msgSend)(app, sel_registerName("keyWindow")) : nil;
    id scene = keyWin ? [keyWin valueForKey:@"windowScene"] : nil;
    if (!scene) {
        NSArray *wins = [app valueForKey:@"windows"];
        for (id w in wins) { id ws=[w valueForKey:@"windowScene"]; if (ws){ scene=ws; break; } }
    }
    if (scene) {
        window = [(id)wc alloc]; window = ((id(*)(id,SEL,id))objc_msgSend)(window, sel_registerName("initWithWindowScene:"), scene);
        SQBridgeLog(@"initWithWindowScene: -> %@", window);
        // 尝试存回单例: PullOverWindow 若有 setSharedWindow / controller 就 bind
    } else {
        SQBridgeLog(@"no window scene available");
    }
    return window;
}

/* ---- hooks ---- */
static id (*orig_sharedWindow)(id,SEL);
static id hook_sharedWindow(id self, SEL _cmd) {
    id w = orig_sharedWindow ? orig_sharedWindow(self,_cmd) : nil;
    SQBridgeLog(@"+sharedWindow called -> %@", w);
    if (!w) {
        w = SQBridgeEnsurePullOverWindow();
        SQBridgeLog(@"+sharedWindow ensured -> %@", w);
    }
    return w ?: w;
}

static void (*orig_pinApp)(id,SEL,id);
static void hook_pinApp(id self, SEL _cmd, id bundleId) {
    SQBridgeLog(@"-pinAppWithBundleId: %@", bundleId);
    SQBridgeEnsurePullOverWindow();
    if (orig_pinApp) orig_pinApp(self,_cmd,bundleId);
}

static id (*orig_initScene)(id,SEL,id);
static id hook_initScene(id self, SEL _cmd, id scene) {
    SQBridgeLog(@"-initWithWindowScene: called");
    id r = orig_initScene ? orig_initScene(self,_cmd,scene) : nil;
    return r;
}

static void SQBridgeHookClassMethod(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls || !sel) return;
    Method m = class_getClassMethod(cls, sel);
    if (m) {
        *orig = method_getImplementation(m);
        class_replaceMethod(object_getClass(cls), sel, hook, method_getTypeEncoding(m));
        SQBridgeLog(@"hooked +%@", NSStringFromSelector(sel));
    } else SQBridgeLog(@"NO +%@", NSStringFromSelector(sel));
}
static void SQBridgeHookInstance(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        *orig = method_getImplementation(m);
        class_replaceMethod(cls, sel, hook, method_getTypeEncoding(m));
        SQBridgeLog(@"hooked -%@", NSStringFromSelector(sel));
    } else SQBridgeLog(@"NO -%@", NSStringFromSelector(sel));
}

static __attribute__((constructor)) void SQBridgeInit(void) {
    // 先清空旧日志
    [[NSFileManager defaultManager] removeItemAtPath:SQBridgeLogPath() error:nil];
    [@"" writeToFile:SQBridgeLogPath() atomically:NO encoding:NSUTF8StringEncoding error:nil];
    SQBridgeLog(@"=== SQBridge v3 init (process=%@) ===", NSProcessInfo.processInfo.processName);
    if (!objc_getClass("SpringBoard")) {
        SQBridgeLog(@"NOT in SpringBoard, skip hooks");
        return;
    }
    SQBridgeLog(@"in SpringBoard; classes: PullOverWindow=%@ PullOverViewController=%@ SquidGesture=%@",
        NSClassFromString(@"PullOverWindow"), NSClassFromString(@"PullOverViewController"),
        NSClassFromString(@"SquidGesturePro") ?: (id)@"?");
    Class pullWin = NSClassFromString(@"PullOverWindow");
    if (pullWin)
        SQBridgeHookClassMethod(pullWin, sel_registerName("sharedWindow"), (IMP)hook_sharedWindow, (IMP*)&orig_sharedWindow);
    Class pullVC = NSClassFromString(@"PullOverViewController");
    if (pullVC) {
        SQBridgeHookInstance(pullVC, sel_registerName("pinAppWithBundleId:"), (IMP)hook_pinApp, (IMP*)&orig_pinApp);
        SQBridgeHookInstance(pullVC, sel_registerName("initWithWindowScene:"), (IMP)hook_initScene, (IMP*)&orig_initScene);
    }
    SQBridgeLog(@"init done; hooks active");
}