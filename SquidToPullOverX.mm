/*
 * SquidToPullOverX.mm — v1.0.8 (稳定版)
 *
 * 目标: 让 SquidGesture 手势"在PullOver打开"驱动 Pull Over X 开小窗。
 * 已验证(日志): SquidGesture 原生手势调 PullOverWindow.sharedWindow 后不再继续。
 *   翻译层在 sharedWindow 被调时, 延迟检查 controller 未打开则用前台 App 兜底开窗。
 *
 * v1.0.8 改动(修复 v1.0.7 崩溃):
 *   - 移除全部高风险系统方法 hook (openURL / launchApplicationWithIdentifier:suspended:)
 *   - 只保留 PullOver X 自身相关的最小 hook (+sharedWindow, pinApp, open)
 *   - 加防重入锁: fallback 里的 pinApp/openTemporary 不会再触发 sharedWindow 递归
 *   - fallback 用 openTemporary(native=0, v1.0.6 已验证不崩且能 open) 而非 pinApp
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>

static NSString *Path(void){ return @"/var/mobile/Documents/SQBridge.log"; }
static BOOL gBusy = NO;   // 防重入锁

static void SQBridgeWrite(NSString *msg) {
    NSString *line=[msg stringByAppendingString:@"\n"];
    NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:Path()];
    if(!fh){ [line writeToFile:Path() atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    else { @try{[fh seekToEndOfFile];[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];[fh closeFile];}@catch(NSException*e){} }
}
static void SQBridgeLog(NSString *fmt, ...) {
    va_list ap; va_start(ap,fmt);
    NSString *msg=[[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    time_t now=time(NULL); struct tm tm; localtime_r(&now,&tm);
    char tbuf[32]; strftime(tbuf,sizeof(tbuf),"%H:%M:%S",&tm);
    SQBridgeWrite([NSString stringWithFormat:@"%s %@",tbuf,msg]);
}

/* 取当前前台 App bundleId — 优先复用 Pull Over X 自己的 frontMostBundleId */
static NSString *SQBridgeFrontMostBundleId(void) {
    Class helper=NSClassFromString(@"POApplicationHelper");
    if(helper && [helper respondsToSelector:NSSelectorFromString(@"frontMostBundleId")]){
        id bid=((id(*)(id,SEL))objc_msgSend)(helper, NSSelectorFromString(@"frontMostBundleId"));
        if([bid isKindOfClass:NSString.class] && [bid length]) return bid;
    }
    Class UIApp=NSClassFromString(@"UIApplication");
    id shared=UIApp?((id(*)(id,SEL))objc_msgSend)(UIApp,sel_registerName("sharedApplication")):nil;
    id app=[shared valueForKey:@"_accessibilityFrontMostApplication"];
    if(app && [(NSObject*)app respondsToSelector:@selector(bundleIdentifier)])
        return [app valueForKey:@"bundleIdentifier"];
    return nil;
}

/* ---- 核心: hook +sharedWindow ---- */
static id (*orig_sharedWindow)(id,SEL);
static id hook_sharedWindow(id self,SEL _cmd){
    id w = orig_sharedWindow ? orig_sharedWindow(self,_cmd) : nil;
    id ctrl = w ? [w valueForKey:@"controller"] : nil;
    SQBridgeLog(@"HOOK +sharedWindow  controller=%@", ctrl);
    // 延迟检查 + 防重入: 若 controller 未打开, 用前台 App 兜底开窗(仅一次)
    if (ctrl && !gBusy) {
        gBusy = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 再次 check: pullOver 自己是否已打开(isOpened)
            NSNumber *opened = nil;
            @try { opened = [ctrl valueForKey:@"isOpened"]; } @catch(NSException*e){}
            BOOL isOpen = [opened boolValue];
            if (!isOpen) {
                NSString *bid = SQBridgeFrontMostBundleId();
                SQBridgeLog(@"fallback trigger; frontmost=%@", bid);
                if (bid.length) {
                    SEL ot = sel_registerName("openTemporaryAppWithBundleId:universalLink:nativeExternalActivation:completion:");
                    if ([(NSObject*)ctrl respondsToSelector:ot]) {
                        SQBridgeLog(@"calling openTemporary %@ (native=0)", bid);
                        ((void(*)(id,SEL,id,id,BOOL,id))objc_msgSend)(ctrl, ot, bid, nil, NO, nil);
                    } else {
                        SEL pa=@selector(pinAppWithBundleId:);
                        if ([(NSObject*)ctrl respondsToSelector:pa]) {
                            SQBridgeLog(@"calling pinApp %@", bid);
                            ((void(*)(id,SEL,id))objc_msgSend)(ctrl, pa, bid);
                        }
                    }
                }
            }
            gBusy = NO;
        });
    }
    return w;
}

static void SQBridgeHookClass(Class cls,SEL sel,IMP hook,IMP*orig){
    if(!cls||!sel)return;
    Method m=class_getClassMethod(cls,sel);
    if(m){ *orig=method_getImplementation(m);
        class_replaceMethod(object_getClass(cls),sel,hook,method_getTypeEncoding(m));
        SQBridgeLog(@"hooked +%@",NSStringFromSelector(sel)); }
    else SQBridgeLog(@"NO +%@",NSStringFromSelector(sel));
}
static void SQBridgeHookInstance(Class cls,SEL sel,IMP hook,IMP*orig){
    if(!cls||!sel)return;
    Method m=class_getInstanceMethod(cls,sel);
    if(m){ *orig=method_getImplementation(m);
        class_replaceMethod(cls,sel,hook,method_getTypeEncoding(m));
        SQBridgeLog(@"hooked -%@",NSStringFromSelector(sel)); }
    else SQBridgeLog(@"NO -%@",NSStringFromSelector(sel));
}

static __attribute__((constructor)) void SQBridgeInit(void) {
    [[NSFileManager defaultManager] removeItemAtPath:Path() error:nil];
    SQBridgeLog(@"=== SQBridge v1.0.8 init (process=%@) ===", NSProcessInfo.processInfo.processName);
    if(!objc_getClass("SpringBoard")){ SQBridgeLog(@"not SpringBoard"); return; }
    // 只 hook PullOver X 自身的最小面, 降低崩溃风险
    Class pullWin=NSClassFromString(@"PullOverWindow");
    if(pullWin) SQBridgeHookClass(pullWin, sel_registerName("sharedWindow"),(IMP)hook_sharedWindow,(IMP*)&orig_sharedWindow);
    Class pullVC=NSClassFromString(@"PullOverViewController");
    if(pullVC){
        // 只留 sharedWindow 兜底即可; 不再 hook pinApp/open 等(避免干扰 PullOver 内部)
    } else {
        SQBridgeLog(@"WARN: PullOverViewController not present");
    }
    SQBridgeLog(@"init done");
}