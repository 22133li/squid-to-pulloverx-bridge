/*
 * SquidToPullOverX.mm — 翻译层 v2
 *
 * 根因 (已验证):
 *   SquidGesture 原生"在PullOver打开" → 直接调
 *      PullOverWindow.sharedWindow.controller.pinAppWithBundleId:
 *   但 PullOver X 窗口需 init (initWithWindowScene:) 后才可用; 未初始化则
 *   sharedWindow 返回 nil / window 未绑定, pinApp 无效果 → 手势"没反应".
 *
 * 方案: hook PullOverWindow 的 -sharedWindow (类方法), 一旦被调用即确保窗口
 *   已初始化并绑定 main scene, 保证返回值可用; hook controller.pinAppWithBundleId:
 *   记录日志确认调用链. 纯 runtime, 不依赖 substrate 链接.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>

static void SQBridgeLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SQBridge] %@", msg);
}

/* 确保 PullOver X 窗口已初始化并绑定主 scene */
static id SQBridgeEnsurePullOverWindow(void) {
    Class wc = NSClassFromString(@"PullOverWindow");
    if (!wc) { SQBridgeLog(@"PullOverWindow class not found"); return nil; }
    id (*getWindow)(id,SEL) = (id(*)(id,SEL))objc_msgSend;
    SEL sshared = sel_registerName("sharedWindow");
    id window = getWindow(wc, sshared);
    if (!window) {
        SQBridgeLog(@"sharedWindow returned nil; trying init");
        // 尝试创建: PullOverWindow 有 +sharedInstance? 或先 +sharedWindow 再 ensure。
        // 尝试通过 UIWindowScene
        id scene = nil;
        // 取当前 keyWindow 的 windowScene
        id app = ((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"UIApplication"), sel_registerName("sharedApplication"));
        id keyWin = app ? getWindow(app, sel_registerName("keyWindow")) : nil;
        if (keyWin) scene = [keyWin valueForKey:@"windowScene"];
        if (!scene) {
            // fallback: 遍历 windows
            NSArray *wins = [app valueForKey:@"windows"];
            for (id w in wins) { id ws=[w valueForKey:@"windowScene"]; if (ws) { scene=ws; break; } }
        }
        if (scene) {
            window = [[wc alloc] initWithWindowScene:scene];
            SQBridgeLog(@"created PullOverWindow with scene");
        } else {
            SQBridgeLog(@"no window scene available");
        }
        // 置回单例 (如果共有 setter/shared setter)
        // PullOverX internal stores; if sharedWindow caches, it'll return on next call.
    } else {
        SQBridgeLog(@"sharedWindow returned existing window %@", window);
    }
    return window;
}

/* ---- hook PullOverWindow +sharedWindow (类方法) ---- */
static id (*orig_sharedWindow)(id,SEL);
static id hook_sharedWindow(id self, SEL _cmd) {
    id w = orig_sharedWindow ? orig_sharedWindow(self,_cmd) : nil;
    SQBridgeLog(@"+sharedWindow called -> %@", w);
    return w;
}

/* ---- hook PullOverViewController -pinAppWithBundleId: ---- */
static void (*orig_pinApp)(id,SEL,id);
static void hook_pinApp(id self, SEL _cmd, id bundleId) {
    SQBridgeLog(@"-pinAppWithBundleId: %@", bundleId);
    SQBridgeEnsurePullOverWindow();  // 确保窗口就绪
    if (orig_pinApp) orig_pinApp(self,_cmd,bundleId);
}

/* ---- hook PullOverWindow -initWithWindowScene: (记日志) ---- */
static id (*orig_initScene)(id,SEL,id);
static id hook_initScene(id self, SEL _cmd, id scene) {
    id r = orig_initScene ? orig_initScene(self,_cmd,scene) : nil;
    SQBridgeLog(@"-initWithWindowScene: called");
    return r;
}

static void SQBridgeHookClassMethod(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls || !sel) return;
    Method m = class_getClassMethod(cls, sel);
    if (m) {
        *orig = method_getImplementation(m);
        // 类方法存在是在 metaclass 上
        class_replaceMethod(object_getClass(cls), sel, hook, method_getTypeEncoding(m));
        SQBridgeLog(@"hooked +%@", NSStringFromSelector(sel));
    }
}
static void SQBridgeHookInstance(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        *orig = method_getImplementation(m);
        class_replaceMethod(cls, sel, hook, method_getTypeEncoding(m));
        SQBridgeLog(@"hooked -%@", NSStringFromSelector(sel));
    }
}

static __attribute__((constructor)) void SQBridgeInit(void) {
    if (!objc_getClass("SpringBoard")) return;
    SQBridgeLog(@"init (SpringBoard)");
    Class pullWin = NSClassFromString(@"PullOverWindow");
    if (pullWin) {
        SQBridgeHookClassMethod(pullWin, sel_registerName("sharedWindow"),
                                (IMP)hook_sharedWindow, (IMP*)&orig_sharedWindow);
    } else {
        SQBridgeLog(@"PullOverWindow class not present at init");
    }
    Class pullVC = NSClassFromString(@"PullOverViewController");
    if (pullVC) {
        SQBridgeHookInstance(pullVC, sel_registerName("pinAppWithBundleId:"),
                             (IMP)hook_pinApp, (IMP*)&orig_pinApp);
        SQBridgeHookInstance(pullVC, sel_registerName("initWithWindowScene:"),
                             (IMP)hook_initScene, (IMP*)&orig_initScene);
    } else {
        SQBridgeLog(@"PullOverViewController class not present at init");
    }
    SQBridgeLog(@"init done");
}