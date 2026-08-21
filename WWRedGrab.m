#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <sys/mman.h>
#import <pthread.h>
#import <QuartzCore/QuartzCore.h>
#import <libkern/OSCacheControl.h>
#import <string.h>
#import <stdlib.h>

/*
 * WWRedGrab - protocol layer grab for WeCom
 *
 * Binary (5.0.10): preferred base 0x100000000
 *   SendGrabHongBao   @ 0x100bca7bc  (redenvelopes_protocol_backend)
 *   SendUnWrapHongBao @ 0x100bcad00
 *
 * Args (ARM64, from disasm + logs):
 *   x0 = protocol backend this
 *   x1 = hongbaoId  (std::string* or equivalent pointer logged as string)
 *   x2 = hbticket
 *   x3 = (extra / to_vid related)
 *   x4/x5/x6 = sceneid etc (see wrappers)
 *
 * Strategy:
 *  1) Inline-hook SendGrab/SendUnWrap → steal `this` + last tickets
 *  2) On new HB msg → if this ready, call SendGrab+SendUnWrap DIRECTLY (no bubble/window)
 *  3) Fallback: tony_onClick + openBlock (still no window) until this captured
 */

#pragma mark - Config keys

static NSString * const kCfgEnabled   = @"wwrg_enabled";
static NSString * const kCfgDelayMs   = @"wwrg_delay_ms";
static NSString * const kCfgWhitelist = @"wwrg_whitelist";
static NSString * const kCfgTotalFen  = @"wwrg_total_fen";
static NSString * const kCfgGrabCount = @"wwrg_grab_count";
static NSString * const kCfgHistory   = @"wwrg_history";
static NSString * const kCfgBallX     = @"wwrg_ball_x";
static NSString * const kCfgBallY     = @"wwrg_ball_y";

// file offsets from wework binary (unslid VA - 0x100000000)
static const uint64_t kOff_SendGrab   = 0xbca7bcULL;
static const uint64_t kOff_SendUnWrap = 0xbcad00ULL;

#pragma mark - State

static UIButton *gBall;
static UIWindow *gPanelWin;
static NSMutableSet *gDone;
static NSMutableSet *gPending;
static NSMutableSet *gCounted;
static NSObject *gLock;
static BOOL gUIReady;

static void *gProtoThis = NULL;          // stolen backend this
static void *gSlideBase = NULL;          // slid image base
static NSString *gLastHid;
static NSString *gLastConv;
static NSString *gLastWish;
static NSString *gLastTicket;

// original function prologues
typedef uint64_t (*WWRG_SendGrab_t)(void *thiz, void *a1, void *a2, void *a3, void *a4, void *a5);
typedef uint64_t (*WWRG_SendUnWrap_t)(void *thiz, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6);

static WWRG_SendGrab_t   gOrigGrab = NULL;
static WWRG_SendUnWrap_t gOrigUnWrap = NULL;
static uint8_t gGrabTramp[32];
static uint8_t gUnWrapTramp[32];
static BOOL gHooked = NO;

#pragma mark - Log / defaults

static void WWRGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void WWRGLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WWRedGrab] %@", s);
}

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static BOOL WWRGOn(void) {
    if (![D() objectForKey:kCfgEnabled]) return YES;
    return [D() boolForKey:kCfgEnabled];
}
static NSInteger WWRGDelay(void) {
    NSInteger v = [D() integerForKey:kCfgDelayMs];
    if (v < 0) v = 0; if (v > 2000) v = 2000; return v;
}
static NSArray *WWRGWL(void) { return [D() arrayForKey:kCfgWhitelist] ?: @[]; }
static void WWRGSetWL(NSArray *a) { [D() setObject:a?:@[] forKey:kCfgWhitelist]; [D() synchronize]; }
static long long WWRGFenTotal(void) { return (long long)[D() integerForKey:kCfgTotalFen]; }
static NSInteger WWRGCnt(void) { return [D() integerForKey:kCfgGrabCount]; }
static NSString *WWRGYuan(long long fen) { return [NSString stringWithFormat:@"%.2f", fen/100.0]; }

static BOOL WWRGIsWL(NSString *name) {
    if (!name.length) return NO;
    NSString *n = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *w in WWRGWL()) {
        NSString *t = [w stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!t.length) continue;
        if ([n isEqualToString:t] || [n containsString:t] || [t containsString:n]) return YES;
    }
    return NO;
}

static BOOL WWRGBegin(NSString *hid) {
    if (!hid.length) return NO;
    @synchronized (gLock) {
        if ([gDone containsObject:hid] || [gPending containsObject:hid]) return NO;
        [gPending addObject:hid]; return YES;
    }
}
static void WWRGEnd(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) {
        [gPending removeObject:hid];
        [gDone addObject:hid];
    }
}
static void WWRGCancel(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) { [gPending removeObject:hid]; }
}

static id WWRGCall(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static void WWRGCallV(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return;
    ((void (*)(id, SEL))objc_msgSend)(o, s);
}
static unsigned long long WWRGCallQ(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return 0;
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(o, s);
}

static long long WWRGParseFen(NSString *s) {
    if (!s.length) return 0;
    NSMutableString *m = [NSMutableString string];
    BOOL dot = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [m appendFormat:@"%C", c];
        else if (c == '.' && !dot) { [m appendString:@"."]; dot = YES; }
    }
    if (!m.length) return 0;
    return (long long)llround(m.doubleValue * 100.0);
}

static void WWRGRefreshBall(void);

static void WWRGBook(NSString *conv, NSString *hid, long long fen, NSString *wish) {
    if (hid.length) {
        @synchronized (gLock) {
            if ([gCounted containsObject:hid]) { WWRGEnd(hid); return; }
            [gCounted addObject:hid];
        }
        WWRGEnd(hid);
    }
    if (fen < 0) fen = 0;
    NSMutableArray *arr = [[D() arrayForKey:kCfgHistory] mutableCopy] ?: [NSMutableArray array];
    [arr insertObject:@{
        @"t": @(NSDate.date.timeIntervalSince1970),
        @"conv": conv ?: @"", @"hid": hid ?: @"",
        @"fen": @(fen), @"wish": wish ?: @""
    } atIndex:0];
    while (arr.count > 150) [arr removeLastObject];
    [D() setObject:arr forKey:kCfgHistory];
    if (fen > 0) [D() setInteger:(NSInteger)(WWRGFenTotal() + fen) forKey:kCfgTotalFen];
    [D() setInteger:WWRGCnt() + 1 forKey:kCfgGrabCount];
    [D() synchronize];
    WWRGLog(@"入账 ¥%@ (%lld分) hid=%@ conv=%@", WWRGYuan(fen), fen, hid, conv);
    dispatch_async(dispatch_get_main_queue(), ^{ WWRGRefreshBall(); });
}

#pragma mark - ARM64 inline hook

static BOOL WWRGMakeRx(void *p, size_t n) {
    uintptr_t start = (uintptr_t)p & ~0x3FFFULL;
    uintptr_t end = ((uintptr_t)p + n + 0x3FFF) & ~0x3FFFULL;
    return mprotect((void *)start, end - start, PROT_READ | PROT_WRITE | PROT_EXEC) == 0;
}

// write: LDR X16, #8; BR X16; .quad target
static void WWRGWriteAbsJump(void *at, void *target) {
    uint32_t *p = (uint32_t *)at;
    p[0] = 0x58000050; // LDR X16, #8
    p[1] = 0xD61F0200; // BR X16
    memcpy(p + 2, &target, 8);
}

// trampoline: first 16 bytes original, then jump to orig+16
static void *WWRGBuildTramp(void *func, uint8_t *buf) {
    memcpy(buf, func, 16);
    WWRGWriteAbsJump(buf + 16, (uint8_t *)func + 16);
    // clear i-cache
    sys_icache_invalidate(buf, 32);
    return buf;
}

static uint64_t WWRGHookedGrab(void *thiz, void *a1, void *a2, void *a3, void *a4, void *a5) {
    if (thiz) {
        gProtoThis = thiz;
        WWRGLog(@"捕获 protocol this=%p (Grab)", thiz);
    }
    // try interpret a1 as NSString* or CFString
    id s1 = (__bridge id)a1;
    if ([s1 isKindOfClass:NSString.class]) {
        gLastHid = [s1 copy];
        WWRGLog(@"Grab hid=%@", s1);
    }
    id s2 = (__bridge id)a2;
    if ([s2 isKindOfClass:NSString.class]) {
        gLastTicket = [s2 copy];
        WWRGLog(@"Grab ticket=%@", s2);
    }
    return gOrigGrab(thiz, a1, a2, a3, a4, a5);
}

static uint64_t WWRGHookedUnWrap(void *thiz, void *a1, void *a2, void *a3, void *a4, void *a5, void *a6) {
    if (thiz) {
        gProtoThis = thiz;
        WWRGLog(@"捕获 protocol this=%p (UnWrap)", thiz);
    }
    id s1 = (__bridge id)a1;
    if ([s1 isKindOfClass:NSString.class]) {
        gLastHid = [s1 copy];
        WWRGLog(@"UnWrap hid=%@", s1);
    }
    id s2 = (__bridge id)a2;
    if ([s2 isKindOfClass:NSString.class]) {
        gLastTicket = [s2 copy];
        WWRGLog(@"UnWrap ticket=%@", s2);
    }
    uint64_t r = gOrigUnWrap(thiz, a1, a2, a3, a4, a5, a6);
    // unwrap success often followed by amount callbacks
    return r;
}

static void *WWRGFindWeworkBase(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        // main executable often ends with /wework
        if (strstr(nm, "/wework") || strstr(nm, "wework.app/wework")) {
            const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            WWRGLog(@"wework image %s slide=0x%lx hdr=%p", nm, (long)slide, hdr);
            return (void *)((uintptr_t)0x100000000ULL + slide);
        }
    }
    // fallback: image 0
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    WWRGLog(@"fallback image0 slide=0x%lx", (long)slide);
    return (void *)((uintptr_t)0x100000000ULL + slide);
}

static BOOL WWRGInstallCHooks(void) {
    if (gHooked) return YES;
    gSlideBase = WWRGFindWeworkBase();
    if (!gSlideBase) return NO;

    void *grab = (uint8_t *)gSlideBase + kOff_SendGrab;
    void *unwrap = (uint8_t *)gSlideBase + kOff_SendUnWrap;
    WWRGLog(@"SendGrab @ %p  SendUnWrap @ %p", grab, unwrap);

    // sanity: first insn should look like SUB SP or STP
    uint32_t g0 = *(uint32_t *)grab;
    uint32_t u0 = *(uint32_t *)unwrap;
    WWRGLog(@"Grab head %08x UnWrap head %08x", g0, u0);

    if (!WWRGMakeRx(grab, 16) || !WWRGMakeRx(unwrap, 16)) {
        WWRGLog(@"mprotect fail");
        return NO;
    }
    if (!WWRGMakeRx(gGrabTramp, 32) || !WWRGMakeRx(gUnWrapTramp, 32)) {
        WWRGLog(@"tramp mprotect fail");
        return NO;
    }

    gOrigGrab = (WWRG_SendGrab_t)WWRGBuildTramp(grab, gGrabTramp);
    gOrigUnWrap = (WWRG_SendUnWrap_t)WWRGBuildTramp(unwrap, gUnWrapTramp);

    WWRGWriteAbsJump(grab, (void *)WWRGHookedGrab);
    WWRGWriteAbsJump(unwrap, (void *)WWRGHookedUnWrap);
    sys_icache_invalidate(grab, 16);
    sys_icache_invalidate(unwrap, 16);

    gHooked = YES;
    WWRGLog(@"C函数 hook 完成 (协议层)");
    return YES;
}

// Direct protocol call — a1/a2 as NSString* tried first (many WW paths pass NSString*)
static void WWRGProtoGrab(NSString *hid, NSString *ticket) {
    if (!gHooked || !gOrigGrab) { WWRGLog(@"Grab orig 未就绪"); return; }
    if (!gProtoThis) { WWRGLog(@"protocol this 未捕获, 等一次系统调用或走 fallback"); return; }
    if (!hid.length) return;

    WWRGLog(@"协议直调 SendGrab hid=%@ ticket=%@ this=%p", hid, ticket, gProtoThis);

    // Pass NSString* — if backend expects std::string*, this may fail; fallback path handles.
    // Many Tencent iOS paths use NSString* at the ObjC→C++ boundary before conversion.
    void *pHid = (__bridge void *)hid;
    void *pTk  = (__bridge void *)(ticket ?: @"");
    // sceneid often 0 / small int in x4 or x5 — pass 0
    @try {
        gOrigGrab(gProtoThis, pHid, pTk, NULL, NULL, NULL);
    } @catch (NSException *ex) {
        WWRGLog(@"Grab 异常 %@", ex);
    }
}

static void WWRGProtoUnWrap(NSString *hid, NSString *ticket) {
    if (!gHooked || !gOrigUnWrap || !gProtoThis) return;
    if (!hid.length) return;
    WWRGLog(@"协议直调 SendUnWrap hid=%@ ticket=%@", hid, ticket);
    void *pHid = (__bridge void *)hid;
    void *pTk  = (__bridge void *)(ticket ?: gLastTicket ?: @"");
    @try {
        gOrigUnWrap(gProtoThis, pHid, pTk, NULL, NULL, NULL, NULL);
    } @catch (NSException *ex) {
        WWRGLog(@"UnWrap 异常 %@", ex);
    }
}

#pragma mark - Swizzle helpers

static void WWRGSwizzle(Class cls, SEL o, SEL n) {
    if (!cls) return;
    Method om = class_getInstanceMethod(cls, o);
    Method nm = class_getInstanceMethod(cls, n);
    if (!om || !nm) return;
    if (class_addMethod(cls, o, method_getImplementation(nm), method_getTypeEncoding(nm)))
        class_replaceMethod(cls, n, method_getImplementation(om), method_getTypeEncoding(om));
    else method_exchangeImplementations(om, nm);
    WWRGLog(@"swizzle %@ %s", cls, sel_getName(o));
}

static void WWRGHook(Class cls, SEL o, SEL n, id block) {
    if (!cls || !class_getInstanceMethod(cls, o)) return;
    Method om = class_getInstanceMethod(cls, o);
    class_addMethod(cls, n, imp_implementationWithBlock(block), method_getTypeEncoding(om));
    WWRGSwizzle(cls, o, n);
}

#pragma mark - Message → protocol grab

static BOOL WWRGIsHB(id item) {
    if (!item) return NO;
    NSString *cn = NSStringFromClass([item class]);
    if ([cn containsString:@"MessageRedEnvelopes"] || [cn containsString:@"LishiRedEnvelopes"]) return YES;
    return class_getInstanceMethod([item class], @selector(hongbaoID)) != NULL;
}
static NSString *WWRGHidOf(id item) {
    id h = WWRGCall(item, @selector(hongbaoID));
    return [h isKindOfClass:NSString.class] ? h : nil;
}
static NSString *WWRGWishOf(id item) {
    id w = WWRGCall(item, @selector(wishingWording));
    if ([w isKindOfClass:NSString.class]) return w;
    w = WWRGCall(item, @selector(lishingWording));
    return [w isKindOfClass:NSString.class] ? w : @"";
}
static NSString *WWRGTicketOf(id item) {
    id t = WWRGCall(item, @selector(hbTicket));
    if ([t isKindOfClass:NSString.class] && [t length]) return t;
    // try KVC common names
    @try {
        t = [item valueForKey:@"hbTicket"];
        if ([t isKindOfClass:NSString.class] && [t length]) return t;
    } @catch (__unused NSException *e) {}
    @try {
        t = [item valueForKey:@"mHongbaoTicket"];
        if ([t isKindOfClass:NSString.class] && [t length]) return t;
    } @catch (__unused NSException *e) {}
    return gLastTicket;
}

static void WWRGFallbackTony(id msg, NSString *hid) {
    Class bubbleCls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
    if (!bubbleCls) { WWRGCancel(hid); return; }
    id bubble = [[bubbleCls alloc] init];
    if ([bubble respondsToSelector:@selector(setMessage:)])
        ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), msg);
    else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)])
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), msg, 0);
    if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)])
        WWRGCallV(bubble, @selector(tony_onClickHongbaoMessage));
    else
        WWRGCallV(bubble, @selector(onClickHongbaoMessage));
    objc_setAssociatedObject(msg, "wwrg_keep", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(msg, "wwrg_keep", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    WWRGLog(@"fallback tony_onClick (仍无窗, 仅参数组装)");
}

static void WWRGGrabMsg(id msg, NSString *conv) {
    if (!WWRGOn() || !msg) return;
    if (WWRGIsWL(conv)) { WWRGLog(@"白名单 %@", conv); return; }

    id item = WWRGCall(msg, @selector(messageItem));
    if (!WWRGIsHB(item)) {
        NSArray *items = WWRGCall(msg, @selector(messageItems));
        if ([items isKindOfClass:NSArray.class])
            for (id it in items) if (WWRGIsHB(it)) { item = it; break; }
    }
    if (!WWRGIsHB(item)) return;

    NSString *hid = WWRGHidOf(item);
    if (!hid.length) hid = [NSString stringWithFormat:@"t%p%ld", msg, (long)time(NULL)];
    if (!WWRGBegin(hid)) return;

    NSString *wish = WWRGWishOf(item);
    NSString *ticket = WWRGTicketOf(item);
    gLastHid = [hid copy];
    gLastConv = [conv ?: @"" copy];
    gLastWish = [wish ?: @"" copy];
    if (ticket.length) gLastTicket = [ticket copy];

    WWRGLog(@"发现红包 hid=%@ ticket=%@ conv=%@ this=%p", hid, ticket, conv, gProtoThis);

    void (^go)(void) = ^{
        if (gProtoThis && gOrigGrab) {
            // pure protocol path
            WWRGProtoGrab(hid, ticket ?: gLastTicket);
            // unwrap shortly after grab (server needs grab first)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WWRGProtoUnWrap(hid, gLastTicket ?: ticket);
            });
            // second unwrap retry
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WWRGProtoUnWrap(hid, gLastTicket ?: ticket);
            });
        } else {
            // need one path to capture this + correct tickets
            WWRGFallbackTony(msg, hid);
        }
    };

    NSInteger dly = WWRGDelay();
    if (dly <= 0) {
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dly * NSEC_PER_MSEC)), dispatch_get_main_queue(), go);
    }
}

static id WWRGWrapMsg(void *p) {
    if (!p) return nil;
    Class cls = NSClassFromString(@"WWKMessage");
    if (!cls) return nil;
    @try {
        void *tmp = p;
        id o = [cls alloc];
        if ([cls instancesRespondToSelector:@selector(initWithMessage:observe:)])
            return ((id (*)(id, SEL, void *, BOOL))objc_msgSend)(o, @selector(initWithMessage:observe:), &tmp, NO);
        if ([cls instancesRespondToSelector:@selector(initWithMessage:)])
            return ((id (*)(id, SEL, void *))objc_msgSend)(o, @selector(initWithMessage:), &tmp);
    } @catch (__unused NSException *e) {}
    return nil;
}

typedef struct { void **begin; void **end; void **cap; } WWRGVec;

static void WWRGOnVec(const void *vec, NSString *conv) {
    if (!vec) return;
    const WWRGVec *v = (const WWRGVec *)vec;
    if (v->begin && v->end && v->end > v->begin) {
        ptrdiff_t n = v->end - v->begin;
        if (n > 0 && n <= 100) {
            for (ptrdiff_t i = 0; i < n; i++) {
                void *p = v->begin[i];
                if (!p) continue;
                id msg = WWRGWrapMsg(p);
                if (!msg) continue;
                WWRGCallV(msg, @selector(parseMessage));
                WWRGGrabMsg(msg, conv);
            }
            return;
        }
    }
    void *one = *(void * const *)vec;
    if (one) {
        id msg = WWRGWrapMsg(one);
        if (msg) { WWRGCallV(msg, @selector(parseMessage)); WWRGGrabMsg(msg, conv); }
    }
}

static NSString *WWRGName(id w) {
    id n = WWRGCall(w, @selector(getName));
    return [n isKindOfClass:NSString.class] ? n : @"";
}

static long long WWRGFenFrom(id o) {
    if (!o) return 0;
    if ([o respondsToSelector:@selector(mSelfRecvAmount)]) {
        unsigned long long a = WWRGCallQ(o, @selector(mSelfRecvAmount));
        if (a > 0 && a < 100000000ULL) return (long long)a;
    }
    if ([o respondsToSelector:@selector(totalAmountYuanStr)]) {
        id y = WWRGCall(o, @selector(totalAmountYuanStr));
        if ([y isKindOfClass:NSString.class]) {
            long long f = WWRGParseFen(y);
            if (f > 0) return f;
        }
    }
    if ([o respondsToSelector:@selector(mTotalAmount)]) {
        unsigned long long a = WWRGCallQ(o, @selector(mTotalAmount));
        if (a > 0 && a < 100000000ULL) return (long long)a;
    }
    if ([o isKindOfClass:NSString.class]) return WWRGParseFen((NSString *)o);
    if ([o isKindOfClass:NSNumber.class]) return [(NSNumber *)o longLongValue];
    return 0;
}

static void WWRGNuke(id v) {
    if ([v isKindOfClass:UIView.class]) {
        UIView *view = v;
        view.hidden = YES; view.alpha = 0;
        view.frame = CGRectMake(-9000,-9000,0,0);
        view.userInteractionEnabled = NO;
    }
}
static void WWRGNukeVC(UIViewController *vc) {
    if (!vc) return;
    WWRGNuke(vc.view);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (vc.presentingViewController) [vc dismissViewControllerAnimated:NO completion:nil];
            else if (vc.navigationController.topViewController == vc)
                [vc.navigationController popViewControllerAnimated:NO];
        } @catch (__unused NSException *e) {}
    });
}

static void WWRGInvokeBlock(id block) {
    if (!block) return;
    @try { void (^b)(void)=block; b(); return; } @catch(__unused NSException *e){}
    @try { void (^b)(id)=block; b(nil); return; } @catch(__unused NSException *e){}
    @try { void (^b)(BOOL)=block; b(YES); return; } @catch(__unused NSException *e){}
}

#pragma mark - UI panel

@interface WWRGPanelController : UIViewController <UITableViewDelegate,UITableViewDataSource,UITextFieldDelegate>
@property (nonatomic,strong) UISwitch *enSw;
@property (nonatomic,strong) UISlider *delay;
@property (nonatomic,strong) UILabel *delayLab;
@property (nonatomic,strong) UILabel *stats;
@property (nonatomic,strong) UILabel *protoLab;
@property (nonatomic,strong) UITextField *field;
@property (nonatomic,strong) UITableView *wlTable;
@property (nonatomic,strong) UITableView *hisTable;
@property (nonatomic,strong) NSMutableArray *wl;
@property (nonatomic,strong) NSArray *his;
@property (nonatomic,strong) UISegmentedControl *seg;
@end

@implementation WWRGPanelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    self.wl = [WWRGWL() mutableCopy] ?: [NSMutableArray array];
    self.his = [D() arrayForKey:kCfgHistory] ?: @[];
    CGFloat W = self.view.bounds.size.width; CGFloat y = 52;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16,14,W-100,30)];
    t.text=@"企业微信秒抢红包"; t.textColor=UIColor.whiteColor;
    t.font=[UIFont boldSystemFontOfSize:18]; t.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];

    UIButton *c=[UIButton buttonWithType:UIButtonTypeSystem];
    c.frame=CGRectMake(W-72,12,56,34); c.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin;
    [c setTitle:@"关闭" forState:UIControlStateNormal]; [c setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [c addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:c];

    UILabel *el=[[UILabel alloc] initWithFrame:CGRectMake(16,y,160,28)];
    el.text=@"自动抢红包"; el.textColor=UIColor.whiteColor; el.font=[UIFont systemFontOfSize:16];
    [self.view addSubview:el];
    self.enSw=[[UISwitch alloc] initWithFrame:CGRectMake(W-70,y,51,31)];
    self.enSw.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin; self.enSw.on=WWRGOn();
    [self.enSw addTarget:self action:@selector(onEn:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.enSw]; y+=40;

    self.protoLab=[[UILabel alloc] initWithFrame:CGRectMake(16,y,W-32,36)];
    self.protoLab.numberOfLines=2; self.protoLab.font=[UIFont systemFontOfSize:12];
    self.protoLab.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.protoLab]; [self refProto]; y+=40;

    UILabel *dl=[[UILabel alloc] initWithFrame:CGRectMake(16,y,180,24)];
    dl.text=@"延迟(0最快)"; dl.textColor=UIColor.whiteColor; dl.font=[UIFont systemFontOfSize:16];
    [self.view addSubview:dl];
    self.delayLab=[[UILabel alloc] initWithFrame:CGRectMake(W-100,y,84,24)];
    self.delayLab.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin;
    self.delayLab.textColor=UIColor.lightGrayColor;
    self.delayLab.font=[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.delayLab.textAlignment=NSTextAlignmentRight;
    [self.view addSubview:self.delayLab]; y+=26;
    self.delay=[[UISlider alloc] initWithFrame:CGRectMake(16,y,W-32,30)];
    self.delay.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    self.delay.minimumValue=0; self.delay.maximumValue=1000; self.delay.value=(float)WWRGDelay();
    [self.delay addTarget:self action:@selector(onDelay:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.delay]; [self refDelay]; y+=36;

    self.stats=[[UILabel alloc] initWithFrame:CGRectMake(16,y,W-32,44)];
    self.stats.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    self.stats.textColor=[UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    self.stats.font=[UIFont boldSystemFontOfSize:16]; self.stats.numberOfLines=2;
    [self.view addSubview:self.stats]; [self refStats]; y+=48;

    UIButton *rst=[UIButton buttonWithType:UIButtonTypeSystem];
    rst.frame=CGRectMake(16,y,100,30);
    [rst setTitle:@"清空统计" forState:UIControlStateNormal];
    [rst setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.35 alpha:1] forState:UIControlStateNormal];
    [rst addTarget:self action:@selector(onRst) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:rst]; y+=38;

    self.seg=[[UISegmentedControl alloc] initWithItems:@[@"白名单",@"抢包记录"]];
    self.seg.frame=CGRectMake(16,y,W-32,32); self.seg.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    self.seg.selectedSegmentIndex=0;
    [self.seg addTarget:self action:@selector(onSeg) forControlEvents:UIControlEventValueChanged];
    if (@available(iOS 13.0,*)) self.seg.selectedSegmentTintColor=[UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateSelected];
    [self.view addSubview:self.seg]; y+=42;

    self.field=[[UITextField alloc] initWithFrame:CGRectMake(16,y,W-100,36)];
    self.field.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    self.field.backgroundColor=[UIColor colorWithWhite:0.16 alpha:1];
    self.field.textColor=UIColor.whiteColor;
    self.field.attributedPlaceholder=[[NSAttributedString alloc] initWithString:@"会话名包含则不抢" attributes:@{NSForegroundColorAttributeName:UIColor.grayColor}];
    self.field.layer.cornerRadius=8;
    self.field.leftView=[[UIView alloc] initWithFrame:CGRectMake(0,0,10,36)];
    self.field.leftViewMode=UITextFieldViewModeAlways;
    self.field.returnKeyType=UIReturnKeyDone; self.field.delegate=self;
    [self.view addSubview:self.field];

    UIButton *add=[UIButton buttonWithType:UIButtonTypeSystem];
    add.frame=CGRectMake(W-76,y,60,36); add.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"添加" forState:UIControlStateNormal]; [add setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    add.backgroundColor=[UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1]; add.layer.cornerRadius=8;
    [add addTarget:self action:@selector(onAdd) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add]; y+=48;

    CGFloat th=MAX(120, self.view.bounds.size.height-y-22);
    self.wlTable=[[UITableView alloc] initWithFrame:CGRectMake(0,y,W,th) style:UITableViewStylePlain];
    self.wlTable.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.wlTable.backgroundColor=UIColor.clearColor; self.wlTable.delegate=self; self.wlTable.dataSource=self; self.wlTable.tag=1;
    [self.view addSubview:self.wlTable];
    self.hisTable=[[UITableView alloc] initWithFrame:self.wlTable.frame style:UITableViewStylePlain];
    self.hisTable.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.hisTable.backgroundColor=UIColor.clearColor; self.hisTable.delegate=self; self.hisTable.dataSource=self; self.hisTable.tag=2;
    self.hisTable.hidden=YES; [self.view addSubview:self.hisTable];
}
- (void)refDelay { self.delayLab.text=[NSString stringWithFormat:@"%ldms",(long)self.delay.value]; }
- (void)refStats { self.stats.text=[NSString stringWithFormat:@"累计金额 ¥%@\n成功 %ld 次", WWRGYuan(WWRGFenTotal()), (long)WWRGCnt()]; }
- (void)refProto {
    if (gProtoThis) {
        self.protoLab.text=[NSString stringWithFormat:@"协议层: 已就绪 this=%p\n模式: SendGrab/SendUnWrap 直调", gProtoThis];
        self.protoLab.textColor=[UIColor colorWithRed:0.3 green:1 blue:0.4 alpha:1];
    } else {
        self.protoLab.text=@"协议层: 等待捕获(收到/点开任一红包后激活)\n激活前用无窗 fallback";
        self.protoLab.textColor=[UIColor colorWithRed:1 green:0.75 blue:0.2 alpha:1];
    }
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self refProto]; [self refStats]; }
- (void)onEn:(UISwitch *)s { [D() setBool:s.on forKey:kCfgEnabled]; [D() synchronize]; WWRGRefreshBall(); }
- (void)onDelay:(UISlider *)s { [D() setInteger:(NSInteger)s.value forKey:kCfgDelayMs]; [D() synchronize]; [self refDelay]; }
- (void)onRst {
    [D() setInteger:0 forKey:kCfgTotalFen]; [D() setInteger:0 forKey:kCfgGrabCount];
    [D() setObject:@[] forKey:kCfgHistory]; [D() synchronize];
    @synchronized(gLock){ [gCounted removeAllObjects]; }
    self.his=@[]; [self.hisTable reloadData]; [self refStats]; WWRGRefreshBall();
}
- (void)onAdd {
    NSString *t=[self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
    if (![self.wl containsObject:t]){ [self.wl addObject:t]; WWRGSetWL(self.wl); [self.wlTable reloadData]; }
    self.field.text=@""; [self.field resignFirstResponder];
}
- (void)onSeg {
    BOOL w=self.seg.selectedSegmentIndex==0;
    self.wlTable.hidden=!w; self.hisTable.hidden=w; self.field.hidden=!w;
    if(!w){ self.his=[D() arrayForKey:kCfgHistory]?:@[]; [self.hisTable reloadData]; }
}
- (void)close { gPanelWin.hidden=YES; gPanelWin=nil; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self onAdd]; return YES; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return tv.tag==1?self.wl.count:self.his.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c=[tv dequeueReusableCellWithIdentifier:@"c"];
    if(!c){ c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        c.backgroundColor=UIColor.clearColor; c.textLabel.textColor=UIColor.whiteColor;
        c.detailTextLabel.textColor=UIColor.lightGrayColor; c.selectionStyle=UITableViewCellSelectionStyleNone; }
    if(tv.tag==1){ c.textLabel.text=self.wl[ip.row]; c.detailTextLabel.text=@"不抢"; }
    else {
        NSDictionary *it=self.his[ip.row];
        c.textLabel.text=[NSString stringWithFormat:@"¥%@  %@", WWRGYuan([it[@"fen"] longLongValue]), it[@"conv"]?:@""];
        NSDateFormatter *f=[NSDateFormatter new]; f.dateFormat=@"MM-dd HH:mm:ss";
        c.detailTextLabel.text=[NSString stringWithFormat:@"%@  %@", [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[it[@"t"] doubleValue]]], it[@"wish"]?:@""];
    }
    return c;
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return tv.tag==1; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if(tv.tag!=1||es!=UITableViewCellEditingStyleDelete) return;
    [self.wl removeObjectAtIndex:ip.row]; WWRGSetWL(self.wl);
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip { return @"删除"; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return tv.tag==1?46:58; }
@end

static void WWRGShowPanel(void) {
    if (gPanelWin){ gPanelWin.hidden=NO; return; }
    CGRect sb=UIScreen.mainScreen.bounds;
    CGFloat w=MIN(sb.size.width-20,390), h=MIN(sb.size.height*0.78,660);
    gPanelWin=[[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width-w)/2,(sb.size.height-h)/2,w,h)];
    gPanelWin.windowLevel=UIWindowLevelAlert+10;
    gPanelWin.layer.cornerRadius=14; gPanelWin.clipsToBounds=YES;
    gPanelWin.rootViewController=[WWRGPanelController new];
    gPanelWin.hidden=NO;
}
static void WWRGRefreshBall(void) {
    if (!gBall) return;
    BOOL on=WWRGOn();
    NSString *t = on ? [NSString stringWithFormat:@"¥%@", WWRGYuan(WWRGFenTotal())] : @"关";
    if (on && gProtoThis) t = [NSString stringWithFormat:@"P\n¥%@", WWRGYuan(WWRGFenTotal())];
    [gBall setTitle:t forState:UIControlStateNormal];
    gBall.backgroundColor = on
        ? (gProtoThis ? [UIColor colorWithRed:0.1 green:0.65 blue:0.25 alpha:0.94]
                      : [UIColor colorWithRed:0.90 green:0.20 blue:0.18 alpha:0.94])
        : [UIColor colorWithWhite:0.35 alpha:0.92];
}
static void WWRGDrag(UIPanGestureRecognizer *pan) {
    UIView *v=pan.view;
    CGPoint t=[pan translationInView:v.superview];
    v.center=CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    if(pan.state==UIGestureRecognizerStateEnded){
        CGRect b=UIScreen.mainScreen.bounds;
        CGFloat x=v.center.x<b.size.width/2?30:b.size.width-30;
        CGFloat y=MIN(MAX(v.center.y,80),b.size.height-80);
        [UIView animateWithDuration:0.18 animations:^{ v.center=CGPointMake(x,y); }];
        [D() setDouble:x forKey:kCfgBallX]; [D() setDouble:y forKey:kCfgBallY]; [D() synchronize];
    }
}
static void WWRGEnsureUI(void) {
    if (gUIReady) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gUIReady) return;
        UIWindow *key=nil;
        if (@available(iOS 13.0,*)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (sc.activationState!=UISceneActivationStateForegroundActive) continue;
                if (![sc isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow){ key=w; break; }
                if (!key) key=((UIWindowScene *)sc).windows.firstObject;
                if (key) break;
            }
        }
        if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            key=UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
        }
        if (!key) return;
        CGFloat x=[D() doubleForKey:kCfgBallX], y=[D() doubleForKey:kCfgBallY];
        if (x<10||y<10){ x=key.bounds.size.width-30; y=key.bounds.size.height*0.55; }
        gBall=[UIButton buttonWithType:UIButtonTypeCustom];
        gBall.frame=CGRectMake(0,0,58,58); gBall.center=CGPointMake(x,y);
        gBall.layer.cornerRadius=29; gBall.clipsToBounds=YES;
        gBall.titleLabel.font=[UIFont boldSystemFontOfSize:11];
        gBall.titleLabel.adjustsFontSizeToFitWidth=YES; gBall.titleLabel.numberOfLines=2;
        gBall.titleLabel.textAlignment=NSTextAlignmentCenter;
        [gBall setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBall.layer.borderWidth=1; gBall.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.35].CGColor;

        Class cls=NSClassFromString(@"WWRGDragProxy");
        if (!cls) {
            cls=objc_allocateClassPair(NSObject.class,"WWRGDragProxy",0);
            class_addMethod(cls, NSSelectorFromString(@"onPan:"),
                imp_implementationWithBlock(^(id s, UIPanGestureRecognizer *p){ WWRGDrag(p); }), "v@:@");
            class_addMethod(cls, NSSelectorFromString(@"onTap"),
                imp_implementationWithBlock(^(id s){
                    if (gPanelWin && !gPanelWin.hidden){ gPanelWin.hidden=YES; gPanelWin=nil; }
                    else WWRGShowPanel();
                }), "v@:");
            objc_registerClassPair(cls);
        }
        static id proxy; if (!proxy) proxy=[cls new];
        [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:proxy action:NSSelectorFromString(@"onPan:")]];
        [gBall addTarget:proxy action:NSSelectorFromString(@"onTap") forControlEvents:UIControlEventTouchUpInside];
        [key addSubview:gBall]; WWRGRefreshBall(); gUIReady=YES;
        WWRGLog(@"悬浮球就绪");
    });
}

#pragma mark - Install ObjC hooks

static void WWRGInstallObjC(void) {
    Class wrap=NSClassFromString(@"WWKConversationWrapper");
    if (wrap) {
        SEL o=@selector(OnAddMessage:end:inConversation:);
        SEL n=NSSelectorFromString(@"wwrg_OnAdd:end:cv:");
        WWRGHook(wrap,o,n,^(id self,const void *vec,BOOL end,void *cv){
            ((void(*)(id,SEL,const void*,BOOL,void*))objc_msgSend)(self,n,vec,end,cv);
            if (WWRGOn()) WWRGOnVec(vec, WWRGName(self));
        });
    }
    Class list=NSClassFromString(@"WWKMessageListController");
    if (list) {
        SEL o=@selector(OnAddMessage:end:inConversation:);
        SEL n=NSSelectorFromString(@"wwrg_listAdd:end:cv:");
        WWRGHook(list,o,n,^(id self,const void *vec,BOOL end,void *cv){
            ((void(*)(id,SEL,const void*,BOOL,void*))objc_msgSend)(self,n,vec,end,cv);
            if (WWRGOn()) WWRGOnVec(vec, @"");
        });
    }
    Class wmsg=NSClassFromString(@"WWKMessage");
    if (wmsg) {
        if (class_getInstanceMethod(wmsg,@selector(p_parseHongBaoMessage:))) {
            SEL n=NSSelectorFromString(@"wwrg_pHB:");
            WWRGHook(wmsg,@selector(p_parseHongBaoMessage:),n,^(id self,const void *m){
                ((void(*)(id,SEL,const void*))objc_msgSend)(self,n,m);
                if (WWRGOn()) WWRGGrabMsg(self, gLastConv?:@"");
            });
        }
        if (class_getInstanceMethod(wmsg,@selector(p_parseLishiHongBaoMessage:))) {
            SEL n=NSSelectorFromString(@"wwrg_pLishi:");
            WWRGHook(wmsg,@selector(p_parseLishiHongBaoMessage:),n,^(id self,const void *m){
                ((void(*)(id,SEL,const void*))objc_msgSend)(self,n,m);
                if (WWRGOn()) WWRGGrabMsg(self, gLastConv?:@"");
            });
        }
    }

    // NEVER show open window: steal openBlock = protocol unwrap path used by client
    Class mgr=NSClassFromString(@"WWRedEnvelopesMgr");
    if (mgr) {
        SEL o2=@selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:);
        if (class_getInstanceMethod(mgr,o2)) {
            SEL n=NSSelectorFromString(@"wwrg_oh2:v:tk:vt:c:m:ob:cb:");
            Method om=class_getInstanceMethod(mgr,o2);
            IMP imp=imp_implementationWithBlock(^(id self,const void *d,id vids,const void *tk,int vt,void *cv,void *msg,id ob,id cb){
                if (WWRGOn()) {
                    // extract ticket if NSString-ish pointer
                    // fire unwrap block ONLY — no window
                    WWRGLog(@"拦截开窗 → 只跑 openBlock(协议UnWrap)");
                    if ([self respondsToSelector:@selector(setOpenBlock:)])
                        ((void(*)(id,SEL,id))objc_msgSend)(self,@selector(setOpenBlock:),ob);
                    WWRGInvokeBlock(ob);
                    // also try direct unwrap if we have this
                    if (gProtoThis && gLastHid) WWRGProtoUnWrap(gLastHid, gLastTicket);
                    return;
                }
                ((void(*)(id,SEL,const void*,id,const void*,int,void*,void*,id,id))objc_msgSend)(
                    self,n,d,vids,tk,vt,cv,msg,ob,cb);
            });
            class_addMethod(mgr,n,imp,method_getTypeEncoding(om));
            WWRGSwizzle(mgr,o2,n);
        }
        SEL o1=@selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:);
        if (class_getInstanceMethod(mgr,o1)) {
            SEL n=NSSelectorFromString(@"wwrg_oh1:v:tk:vt:c:m:");
            Method om=class_getInstanceMethod(mgr,o1);
            IMP imp=imp_implementationWithBlock(^(id self,const void *d,id vids,const void *tk,int vt,void *cv,void *msg){
                if (WWRGOn()) {
                    id ob=WWRGCall(self,@selector(openBlock));
                    if (ob) { WWRGLog(@"oh1 openBlock"); WWRGInvokeBlock(ob); return; }
                    if (gProtoThis && gLastHid) { WWRGProtoUnWrap(gLastHid,gLastTicket); return; }
                }
                ((void(*)(id,SEL,const void*,id,const void*,int,void*,void*))objc_msgSend)(
                    self,n,d,vids,tk,vt,cv,msg);
                if (WWRGOn()) {
                    id ob=WWRGCall(self,@selector(openBlock));
                    if (ob) WWRGInvokeBlock(ob);
                    WWRGCallV(self,@selector(closeHongBaoWindow));
                    id win=nil; Ivar iv=class_getInstanceVariable([self class],"_mHongBaoWindow");
                    if (iv) win=object_getIvar(self,iv);
                    WWRGNuke(win);
                }
            });
            class_addMethod(mgr,n,imp,method_getTypeEncoding(om));
            WWRGSwizzle(mgr,o1,n);
        }
        if (class_getInstanceMethod(mgr,@selector(didOpenRedEvnSuc:))) {
            SEL n=NSSelectorFromString(@"wwrg_didOpen:");
            WWRGHook(mgr,@selector(didOpenRedEvnSuc:),n,^(id self,id arg){
                ((void(*)(id,SEL,id))objc_msgSend)(self,n,arg);
                long long fen=WWRGFenFrom(arg);
                WWRGLog(@"didOpenSuc fen=%lld", fen);
                WWRGBook(gLastConv,gLastHid,fen,gLastWish);
                WWRGCallV(self,@selector(closeHongBaoWindow));
                WWRGCallV(self,@selector(closeResultWindow));
            });
        }
    }

    Class openWin=NSClassFromString(@"WWRedEnvOpenHongBaoWindow");
    if (openWin) {
        if (class_getInstanceMethod(openWin,@selector(didMoveToWindow))) {
            SEL n=NSSelectorFromString(@"wwrg_owMove");
            WWRGHook(openWin,@selector(didMoveToWindow),n,^(id self){
                ((void(*)(id,SEL))objc_msgSend)(self,n);
                if (!WWRGOn()) return;
                WWRGNuke(self);
                id mgrInst=WWRGCall(NSClassFromString(@"WWRedEnvelopesMgr"),@selector(shareInstance));
                id ob=WWRGCall(mgrInst,@selector(openBlock));
                if (ob) WWRGInvokeBlock(ob);
                else if ([self respondsToSelector:@selector(onOpenBtnClick:)])
                    ((void(*)(id,SEL,id))objc_msgSend)(self,@selector(onOpenBtnClick:),nil);
                WWRGCallV(mgrInst,@selector(closeHongBaoWindow));
            });
        }
        if (class_getInstanceMethod(openWin,@selector(layoutSubviews))) {
            SEL n=NSSelectorFromString(@"wwrg_owLay");
            WWRGHook(openWin,@selector(layoutSubviews),n,^(id self){
                ((void(*)(id,SEL))objc_msgSend)(self,n);
                if (WWRGOn()) WWRGNuke(self);
            });
        }
    }

    Class res=NSClassFromString(@"WWRedEnvOpenResultWindow");
    if (res && class_getInstanceMethod(res,@selector(_updateUIData:))) {
        SEL n=NSSelectorFromString(@"wwrg_res:");
        WWRGHook(res,@selector(_updateUIData:),n,^(id self,BOOL f){
            ((void(*)(id,SEL,BOOL))objc_msgSend)(self,n,f);
            if (!WWRGOn()) return;
            WWRGNuke(self);
            long long fen=WWRGFenFrom(self);
            NSString *hid=nil; id h=WWRGCall(self,@selector(mHongBaoID));
            if ([h isKindOfClass:NSString.class]) hid=h;
            WWRGBook(gLastConv, hid?:gLastHid, fen, gLastWish);
            WWRGCallV(self,@selector(_closeRedEnvWindow));
        });
    }

    Class detail=NSClassFromString(@"WWRedEnvDetailViewController");
    if (detail) {
        if (class_getInstanceMethod(detail,@selector(setMSelfRecvAmount:))) {
            SEL n=NSSelectorFromString(@"wwrg_selfAmt:");
            WWRGHook(detail,@selector(setMSelfRecvAmount:),n,^(id self,unsigned long long amt){
                ((void(*)(id,SEL,unsigned long long))objc_msgSend)(self,n,amt);
                if (!WWRGOn()) return;
                WWRGLog(@"自己金额=%llu分", amt);
                if (amt>0) {
                    NSString *hid=nil; id h=WWRGCall(self,@selector(mHongBaoID));
                    if ([h isKindOfClass:NSString.class]) hid=h;
                    WWRGBook(gLastConv, hid?:gLastHid, (long long)amt, gLastWish);
                }
                WWRGNukeVC(self);
            });
        }
        if (class_getInstanceMethod(detail,@selector(viewWillAppear:))) {
            SEL n=NSSelectorFromString(@"wwrg_dWill:");
            WWRGHook(detail,@selector(viewWillAppear:),n,^(id self,BOOL a){
                if (WWRGOn()){ UIView *v=[self view]; v.hidden=YES; v.alpha=0; }
                ((void(*)(id,SEL,BOOL))objc_msgSend)(self,n,a);
                if (WWRGOn()) WWRGNukeVC(self);
            });
        }
    }

    Class header=NSClassFromString(@"WWRedEnvDetailHeaderCellView");
    SEL hset=@selector(setContent:tipsWording:summaryWording:hongbaoType:hongbaoSubType:hongbaoId:amount:wishingWording:showTurnIn:clickTurnIn:);
    if (header && class_getInstanceMethod(header,hset)) {
        SEL n=NSSelectorFromString(@"wwrg_hdr:::::::::");
        Method om=class_getInstanceMethod(header,hset);
        IMP imp=imp_implementationWithBlock(^(id self,unsigned long long content,id tips,id sum,unsigned int ty,unsigned int sub,id hid,unsigned long long amount,id wish,BOOL show,id clk){
            ((void(*)(id,SEL,unsigned long long,id,id,unsigned int,unsigned int,id,unsigned long long,id,BOOL,id))objc_msgSend)(
                self,n,content,tips,sum,ty,sub,hid,amount,wish,show,clk);
            if (WWRGOn() && amount>0) {
                WWRGBook(gLastConv, [hid isKindOfClass:NSString.class]?hid:gLastHid,
                         (long long)amount, [wish isKindOfClass:NSString.class]?wish:gLastWish);
            }
        });
        class_addMethod(header,n,imp,method_getTypeEncoding(om));
        WWRGSwizzle(header,hset,n);
    }

    Class bubble=NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
    if (bubble && class_getInstanceMethod(bubble,@selector(updateData))) {
        SEL n=NSSelectorFromString(@"wwrg_bUpd");
        WWRGHook(bubble,@selector(updateData),n,^(id self){
            ((void(*)(id,SEL))objc_msgSend)(self,n);
            if (!WWRGOn()) return;
            id msg=WWRGCall(self,@selector(message));
            if (msg) WWRGGrabMsg(msg,@"");
        });
    }

    WWRGLog(@"ObjC hooks 完成");
}

#pragma mark - ctor

__attribute__((constructor))
static void WWRGInit(void) {
    @autoreleasepool {
        gLock=[NSObject new];
        gDone=[NSMutableSet set];
        gPending=[NSMutableSet set];
        gCounted=[NSMutableSet set];
        WWRGLog(@"加载 bundle=%@", NSBundle.mainBundle.bundleIdentifier);

        // C hooks ASAP
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // small delay so dyld finishes
            usleep(300 * 1000);
            BOOL ok=WWRGInstallCHooks();
            WWRGLog(@"C hook %s", ok?"OK":"FAIL");
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gHooked) WWRGInstallCHooks();
            WWRGInstallObjC();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGEnsureUI();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gUIReady) WWRGEnsureUI();
            WWRGRefreshBall();
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *n){
            if (!gUIReady) WWRGEnsureUI();
            else if (gBall && !gBall.superview){ gUIReady=NO; WWRGEnsureUI(); }
            WWRGRefreshBall();
        }];
    }
}
