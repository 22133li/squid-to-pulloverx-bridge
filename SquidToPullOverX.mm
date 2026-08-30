/*
 * SquidToPullOverX.mm — v4 "录音针" (探针版)
 *
 * 目标: 确定 SquidGesture 手势"在PullOver打开"到底走哪条调用链。
 * 已知(日志): 插件注入成功, PullOverWindow 有效, 但 pinAppWithBundleId: 从未被调。
 * 本版 hook 所有可能入口, 按手势时全部记日志, 锁死它实际触发什么。
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdio.h>
#include <time.h>

static NSString *Path(void){ return @"/var/mobile/Documents/SQBridge.log"; }

/* 检测调用栈是否来自 SquidGesture */
static BOOL SQBridgeCallerIsSquidGesture(void) {
    void *fr[48]; int n=backtrace(fr,48);
    for(int i=1;i<n;i++){
        Dl_info di;
        if(dladdr(fr[i],&di)&&di.dli_fname){
            NSString *p=[NSString stringWithUTF8String:di.dli_fname];
            if([p rangeOfString:@"SquidGesture" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
               [p rangeOfString:@"squidgesturepro" options:NSCaseInsensitiveSearch].location!=NSNotFound){
                return YES;
            }
        }
    }
    return NO;
}
/* 取当前前台 App bundleId */
static NSString *SQBridgeFrontMostBundleId(void) {
    Class UIApp=NSClassFromString(@"UIApplication");
    id shared=UIApp?((id(*)(id,SEL))objc_msgSend)(UIApp,sel_registerName("sharedApplication")):nil;
    id app=[shared valueForKey:@"_accessibilityFrontMostApplication"];
    if(app&&[(NSObject*)app respondsToSelector:@selector(bundleIdentifier)])
        return [app valueForKey:@"bundleIdentifier"];
    return nil;
}

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
static void SQBStack(void) {
    void *fr[24]; int n=backtrace(fr,24);
    for(int i=1;i<n && i<6;i++){
        Dl_info di; 
        if(dladdr(fr[i],&di)&&di.dli_fname){
            NSString*fn=[NSString stringWithUTF8String:di.dli_fname];
            SQBridgeLog(@"caller[%d]=%@ %@",i,[fn lastPathComponent], di.dli_sname?[NSString stringWithUTF8String:di.dli_sname]:@"?");
        }
    }
}

/* ---- 1. hook openURL:options:completionHandler: 看 SquidGesture 是否走 URL ---- */
static void (*orig_openURL)(id,SEL,id,id,id);
static void hook_openURL(id self,SEL _cmd,id url,id opts,id cb){
    SQBridgeLog(@"HOOK openURL:options: %@", url);
    SQBStack();
    if(orig_openURL) orig_openURL(self,_cmd,url,opts,cb);
}

/* ---- 2. hook SBWorkspace launch suspended (系统级挂起启动) ---- */
static BOOL (*orig_launch_id)(id,SEL,id,BOOL);
static BOOL hook_launch_id(id self,SEL _cmd,id bid,BOOL suspended){
    SQBridgeLog(@"HOOK launchApplicationWithIdentifier: %@ suspended=%d", bid, suspended);
    if(suspended){ SQBStack(); }
    return orig_launch_id?orig_launch_id(self,_cmd,bid,suspended):0;
}

/* ---- 3. PullOver X 动作链 ---- */
static id (*orig_sharedWindow)(id,SEL);
static id hook_sharedWindow(id self,SEL _cmd){
    id w=orig_sharedWindow?orig_sharedWindow(self,_cmd):nil;
    id ctrl=w?[w valueForKey:@"controller"]:nil;
    SQBridgeLog(@"HOOK +sharedWindow -> %@  controller=%@", w, ctrl);
    // 检测调用者是 SquidGesture → openNewApp意图
    BOOL fromSquid = SQBridgeCallerIsSquidGesture();
    SQBridgeLog(@"(caller is SquidGesture=%d)", fromSquid);
    if (fromSquid && ctrl) {
        NSString *bid = SQBridgeFrontMostBundleId();
        SQBridgeLog(@"SquidGesture wants PaintOver; frontmost=%@", bid);
        if (bid.length) {
            // 主动替 SquidGesture 完成开窗: 走 PullOver X 认识的 openTemporary
            SEL ot = sel_registerName("openTemporaryAppWithBundleId:universalLink:nativeExternalActivation:completion:");
            if ([(NSObject*)ctrl respondsToSelector:ot]) {
                ((void(*)(id,SEL,id,id,BOOL,id))objc_msgSend)(ctrl, ot, bid, nil, NO, nil);
                SQBridgeLog(@"-> called openTemporary %@ (forced for SquidGesture)", bid);
            } else {
                // fallback pinApp
                SEL pa=@selector(pinAppWithBundleId:);
                if ([(NSObject*)ctrl respondsToSelector:pa]) {
                    ((void(*)(id,SEL,id))objc_msgSend)(ctrl, pa, bid);
                    SQBridgeLog(@"-> called pinApp %@ (forced)", bid);
                }
            }
        }
    }
    return w;
}
static void (*orig_pinApp)(id,SEL,id);
static void hook_pinApp(id self,SEL _cmd,id bid){
    SQBridgeLog(@"HOOK -pinAppWithBundleId: %@", bid);
    SQBStack();
    if(orig_pinApp) orig_pinApp(self,_cmd,bid);
}
static void (*orig_openTmp)(id,SEL,id,id,BOOL,id);
static void hook_openTmp(id self,SEL _cmd,id bid,id ul,BOOL nat,id cb){
    SQBridgeLog(@"HOOK openTemporaryAppWithBundleId: %@ native=%d", bid,nat);
    SQBStack();
    if(orig_openTmp) orig_openTmp(self,_cmd,bid,ul,nat,cb);
}
/* SquidGesture 拿到 sharedWindow 后可能直接调展开方法 */
static void (*orig_vc_open)(id,SEL);
static void hook_vc_open(id self,SEL _cmd){
    SQBridgeLog(@"HOOK PullOverViewController -open");
    SQBStack();
    if(orig_vc_open) orig_vc_open(self,_cmd);
}
static void (*orig_vc_close)(id,SEL);
static void hook_vc_close(id self,SEL _cmd){
    SQBridgeLog(@"HOOK PullOverViewController -close");
    if(orig_vc_close) orig_vc_close(self,_cmd);
}

static void SQBridgeHookInstance(Class cls,SEL sel,IMP hook,IMP*orig){
    if(!cls||!sel)return;
    Method m=class_getInstanceMethod(cls,sel);
    if(m){*orig=method_getImplementation(m); class_replaceMethod(cls,sel,hook,method_getTypeEncoding(m));
        SQBridgeLog(@"hooked -%@",NSStringFromSelector(sel));}
    else SQBridgeLog(@"NO -%@",NSStringFromSelector(sel));
}
static void SQBridgeHookClass(Class cls,SEL sel,IMP hook,IMP*orig){
    if(!cls||!sel)return;
    Method m=class_getClassMethod(cls,sel);
    if(m){*orig=method_getImplementation(m); class_replaceMethod(object_getClass(cls),sel,hook,method_getTypeEncoding(m));
        SQBridgeLog(@"hooked +%@",NSStringFromSelector(sel));}
    else SQBridgeLog(@"NO +%@",NSStringFromSelector(sel));
}

#define HOOKIF_CLASS(name, selstr, hook, orig) do { Class c=NSClassFromString(name); if(c) SQBridgeHookInstance(c, sel_registerName(selstr),(IMP)hook,(IMP*)&orig); } while(0)

static __attribute__((constructor)) void SQBridgeInit(void) {
    [[NSFileManager defaultManager] removeItemAtPath:Path() error:nil];
    SQBridgeLog(@"=== SQBridge v4 probe init (process=%@) ===", NSProcessInfo.processInfo.processName);
    if(!objc_getClass("SpringBoard")){ SQBridgeLog(@"not SpringBoard"); return; }

    // URL 打开 (Logos 的两个入口 + 系统)
    HOOKIF_CLASS(@"SpringBoard", "openURL:options:completionHandler:", hook_openURL, orig_openURL);
    HOOKIF_CLASS(@"UIApplication", "openURL:options:completionHandler:", hook_openURL, orig_openURL);

    // 挂起启动
    HOOKIF_CLASS(@"UIApplication", "launchApplicationWithIdentifier:suspended:", hook_launch_id, orig_launch_id);
    HOOKIF_CLASS(@"SBWorkspace",    "launchApplicationWithIdentifier:suspended:", hook_launch_id, orig_launch_id);

    // PullOver X
    Class pullWin=NSClassFromString(@"PullOverWindow");
    if(pullWin) SQBridgeHookClass(pullWin, sel_registerName("sharedWindow"),(IMP)hook_sharedWindow,(IMP*)&orig_sharedWindow);
    Class pullVC=NSClassFromString(@"PullOverViewController");
    if(pullVC){
        SQBridgeHookInstance(pullVC, sel_registerName("pinAppWithBundleId:"),(IMP)hook_pinApp,(IMP*)&orig_pinApp);
        SQBridgeHookInstance(pullVC, sel_registerName("openTemporaryAppWithBundleId:universalLink:nativeExternalActivation:completion:"),(IMP)hook_openTmp,(IMP*)&orig_openTmp);
        SQBridgeHookInstance(pullVC, sel_registerName("open"),(IMP)hook_vc_open,(IMP*)&orig_vc_open);
        SQBridgeHookInstance(pullVC, sel_registerName("close"),(IMP)hook_vc_close,(IMP*)&orig_vc_close);
    }
    SQBridgeLog(@"probe init done");
}