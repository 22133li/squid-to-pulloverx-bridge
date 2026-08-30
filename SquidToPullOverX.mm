/*
 * SquidToPullOverX.mm — 翻译层: 让 SquidGesture 手势驱动 PullOver X 开小窗
 *
 * 已验证:
 *   - SquidGesture 原生"在PullOver打开" → launchApplicationWithIdentifier:suspended:
 *   - PullOver X 1.9.5 只认 pinAppWithBundleId:
 *   均在 SpringBoard 进程内.
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <dlfcn.h>
#include <execinfo.h>

static BOOL SQBridgeCallerIsSquidGesture(void) {
    void *frames[48];
    int n = backtrace(frames, 48);
    for (int i=0;i<n;i++){
        Dl_info info;
        if (dladdr(frames[i],&info) && info.dli_fname){
            NSString *p=[NSString stringWithUTF8String:info.dli_fname];
            if ([p rangeOfString:@"SquidGesture" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
                [p rangeOfString:@"squidgesturepro" options:NSCaseInsensitiveSearch].location!=NSNotFound){
                return YES;
            }
        }
    }
    return NO;
}

static NSString *SQBridgeFrontMostBundleId(void) {
    id app=[[UIApplication sharedApplication] valueForKey:@"_accessibilityFrontMostApplication"];
    if (app && [(NSObject*)app respondsToSelector:@selector(bundleIdentifier)])
        return [app valueForKey:@"bundleIdentifier"];
    return nil;
}

static BOOL SQBridgeOpenInPullOver(NSString *bundleId) {
    if (bundleId.length==0) return NO;
    Class wc=NSClassFromString(@"PullOverWindow");
    if (!wc) return NO;
    id window=[wc performSelector:NSSelectorFromString(@"sharedWindow")];
    if (!window) return NO;
    id ctrl=[window valueForKey:@"controller"];
    if (!ctrl) return NO;
    SEL pin=@selector(pinAppWithBundleId:);
    if ([(NSObject*)ctrl respondsToSelector:pin]){
        [ctrl performSelector:pin withObject:bundleId];
        return YES;
    }
    return NO;
}

static BOOL (*orig_launch)(id,SEL,id,BOOL);
static BOOL hook_launch(id self, SEL _cmd, id identifier, BOOL suspended) {
    NSString *bid=identifier;
    if (suspended && SQBridgeCallerIsSquidGesture()) {
        BOOL r=orig_launch(self,_cmd,identifier,suspended);
        NSString *b = (bid.length?bid:SQBridgeFrontMostBundleId());
        if (b.length) SQBridgeOpenInPullOver(b);
        return r;
    }
    return orig_launch(self,_cmd,identifier,suspended);
}

static __attribute__((constructor)) void SQBridgeInit(void) {
    if (!objc_getClass("SpringBoard")) return;
    SEL sel=@selector(launchApplicationWithIdentifier:suspended:);
    for (NSString *cn in @[@"UIApplication",@"SBWorkspace",@"SpringBoard"]) {
        Class cls=NSClassFromString(cn);
        if (!cls) continue;
        Method m=class_getInstanceMethod(cls,sel);
        if (m){
            orig_launch=(BOOL(*)(id,SEL,id,BOOL))method_getImplementation(m);
            class_replaceMethod(cls,sel,(IMP)hook_launch,method_getTypeEncoding(m));
            NSLog(@"[SQBridge] hooked %@",cn);
            break;
        }
    }
    NSLog(@"[SQBridge] init done");
}