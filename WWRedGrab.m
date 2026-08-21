#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

#pragma mark - Keys

static NSString * const kCfgEnabled     = @"wwrg_enabled";
static NSString * const kCfgDelayMs     = @"wwrg_delay_ms";
static NSString * const kCfgWhitelist   = @"wwrg_whitelist";
static NSString * const kCfgTotalFen    = @"wwrg_total_fen";
static NSString * const kCfgGrabCount   = @"wwrg_grab_count";
static NSString * const kCfgHistory     = @"wwrg_history";
static NSString * const kCfgBallX       = @"wwrg_ball_x";
static NSString * const kCfgBallY       = @"wwrg_ball_y";
static NSString * const kCfgSound       = @"wwrg_sound";
static NSString * const kCfgSkipSelf    = @"wwrg_skip_self";

#pragma mark - State

static UIButton *gBall = nil;
static UIWindow *gPanelWin = nil;
static NSMutableSet *gGrabbedIDs = nil;
static NSMutableSet *gPendingIDs = nil;
static NSObject *gLock = nil;
static BOOL gUIReady = NO;

#pragma mark - Helpers

static void WWRGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void WWRGLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WWRedGrab] %@", s);
}

static NSUserDefaults *WWRGDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static BOOL WWRGEnabled(void) {
    if (![WWRGDefaults() objectForKey:kCfgEnabled]) return YES;
    return [WWRGDefaults() boolForKey:kCfgEnabled];
}

static NSInteger WWRGDelayMs(void) {
    NSInteger v = [WWRGDefaults() integerForKey:kCfgDelayMs];
    if (v < 0) v = 0;
    if (v > 10000) v = 10000;
    return v;
}

static BOOL WWRGSkipSelf(void) {
    if (![WWRGDefaults() objectForKey:kCfgSkipSelf]) return YES;
    return [WWRGDefaults() boolForKey:kCfgSkipSelf];
}

static NSArray<NSString *> *WWRGWhitelist(void) {
    NSArray *a = [WWRGDefaults() arrayForKey:kCfgWhitelist];
    return a ?: @[];
}

static void WWRGSetWhitelist(NSArray<NSString *> *list) {
    [WWRGDefaults() setObject:(list ?: @[]) forKey:kCfgWhitelist];
    [WWRGDefaults() synchronize];
}

static long long WWRGTotalFen(void) {
    return (long long)[WWRGDefaults() integerForKey:kCfgTotalFen];
}

static NSInteger WWRGGrabCount(void) {
    return [WWRGDefaults() integerForKey:kCfgGrabCount];
}

static NSString *WWRGMoneyStr(long long fen) {
    return [NSString stringWithFormat:@"%.2f", fen / 100.0];
}

static void WWRGAddHistory(NSString *conv, NSString *hid, long long fen, NSString *wish) {
    NSMutableArray *arr = [[WWRGDefaults() arrayForKey:kCfgHistory] mutableCopy] ?: [NSMutableArray array];
    NSDictionary *item = @{
        @"t": @([[NSDate date] timeIntervalSince1970]),
        @"conv": conv ?: @"",
        @"hid": hid ?: @"",
        @"fen": @(fen),
        @"wish": wish ?: @""
    };
    [arr insertObject:item atIndex:0];
    while (arr.count > 100) [arr removeLastObject];
    [WWRGDefaults() setObject:arr forKey:kCfgHistory];
    if (fen > 0) {
        [WWRGDefaults() setInteger:(NSInteger)(WWRGTotalFen() + fen) forKey:kCfgTotalFen];
        [WWRGDefaults() setInteger:WWRGGrabCount() + 1 forKey:kCfgGrabCount];
    }
    [WWRGDefaults() synchronize];
}

static BOOL WWRGIsWhitelisted(NSString *name) {
    if (name.length == 0) return NO;
    NSString *n = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *w in WWRGWhitelist()) {
        NSString *t = [w stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        if ([n isEqualToString:t] || [n containsString:t] || [t containsString:n]) return YES;
    }
    return NO;
}

static BOOL WWRGMarkGrabbed(NSString *hid) {
    if (hid.length == 0) return NO;
    @synchronized (gLock) {
        if ([gGrabbedIDs containsObject:hid]) return NO;
        if ([gPendingIDs containsObject:hid]) return NO;
        [gPendingIDs addObject:hid];
        return YES;
    }
}

static void WWRGFinishGrab(NSString *hid) {
    if (hid.length == 0) return;
    @synchronized (gLock) {
        [gPendingIDs removeObject:hid];
        [gGrabbedIDs addObject:hid];
        if (gGrabbedIDs.count > 500) {
            NSArray *all = gGrabbedIDs.allObjects;
            [gGrabbedIDs removeAllObjects];
            [gGrabbedIDs addObjectsFromArray:[all subarrayWithRange:NSMakeRange(all.count - 200, 200)]];
        }
    }
}

static void WWRGCancelPending(NSString *hid) {
    if (hid.length == 0) return;
    @synchronized (gLock) {
        [gPendingIDs removeObject:hid];
    }
}

static id WWRGSafePerform(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static void WWRGSafePerformV(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(obj, sel);
}

static long long WWRGParseYuanToFen(NSString *s) {
    if (s.length == 0) return 0;
    NSMutableString *m = [NSMutableString string];
    BOOL dot = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [m appendFormat:@"%C", c];
        else if (c == '.' && !dot) { [m appendString:@"."]; dot = YES; }
    }
    if (m.length == 0) return 0;
    double yuan = [m doubleValue];
    return (long long)llround(yuan * 100.0);
}

#pragma mark - Swizzle

static void WWRGSwizzle(Class cls, SEL origSel, SEL newSel) {
    if (!cls) return;
    Method om = class_getInstanceMethod(cls, origSel);
    Method nm = class_getInstanceMethod(cls, newSel);
    if (!om || !nm) {
        WWRGLog(@"swizzle miss %@ %s / %s", cls, sel_getName(origSel), sel_getName(newSel));
        return;
    }
    BOOL ok = class_addMethod(cls, origSel, method_getImplementation(nm), method_getTypeEncoding(nm));
    if (ok) {
        class_replaceMethod(cls, newSel, method_getImplementation(om), method_getTypeEncoding(om));
    } else {
        method_exchangeImplementations(om, nm);
    }
    WWRGLog(@"swizzle ok %@ %s", cls, sel_getName(origSel));
}

static void WWRGSwizzleClass(Class cls, SEL origSel, SEL newSel) {
    if (!cls) return;
    Class meta = object_getClass((id)cls);
    WWRGSwizzle(meta, origSel, newSel);
}

#pragma mark - Forward

static void WWRGTryGrabMessage(id wwkMessage, NSString *convName, NSString *convKey);
static void WWRGAutoOpenWindow(id window);
static void WWRGShowPanel(void);
static void WWRGRefreshBallTitle(void);
static void WWRGEnsureUI(void);

#pragma mark - Grab core

static NSString *WWRGHongbaoIDFromItem(id item) {
    if (!item) return nil;
    id hid = WWRGSafePerform(item, @selector(hongbaoID));
    if ([hid isKindOfClass:[NSString class]] && [hid length] > 0) return hid;
    return nil;
}

static NSString *WWRGWishFromItem(id item) {
    if (!item) return @"";
    id w = WWRGSafePerform(item, @selector(wishingWording));
    if ([w isKindOfClass:[NSString class]]) return w;
    w = WWRGSafePerform(item, @selector(lishingWording));
    if ([w isKindOfClass:[NSString class]]) return w;
    return @"";
}

static BOOL WWRGItemIsHongbao(id item) {
    if (!item) return NO;
    NSString *cn = NSStringFromClass([item class]);
    if ([cn containsString:@"MessageRedEnvelopes"] || [cn containsString:@"LishiRedEnvelopes"]) return YES;
    if (class_getInstanceMethod([item class], @selector(hongbaoID))) return YES;
    return NO;
}

static void WWRGTriggerClick(id bubble) {
    if (!bubble) return;
    if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)]) {
        WWRGSafePerformV(bubble, @selector(tony_onClickHongbaoMessage));
        WWRGLog(@"click tony_onClickHongbaoMessage");
        return;
    }
    if ([bubble respondsToSelector:@selector(onClickHongbaoMessage)]) {
        WWRGSafePerformV(bubble, @selector(onClickHongbaoMessage));
        WWRGLog(@"click onClickHongbaoMessage");
        return;
    }
    WWRGLog(@"bubble has no click sel");
}

static void WWRGTryGrabMessage(id wwkMessage, NSString *convName, NSString *convKey) {
    if (!WWRGEnabled()) return;
    if (!wwkMessage) return;

    if (WWRGIsWhitelisted(convName) || WWRGIsWhitelisted(convKey)) {
        WWRGLog(@"skip whitelist conv=%@", convName);
        return;
    }

    id item = WWRGSafePerform(wwkMessage, @selector(messageItem));
    if (!item) {
        NSArray *items = WWRGSafePerform(wwkMessage, @selector(messageItems));
        if ([items isKindOfClass:[NSArray class]]) {
            for (id it in items) {
                if (WWRGItemIsHongbao(it)) { item = it; break; }
            }
        }
    }
    if (!WWRGItemIsHongbao(item)) return;

    NSString *hid = WWRGHongbaoIDFromItem(item);
    if (hid.length == 0) {
        hid = [NSString stringWithFormat:@"tmp_%p_%@", wwkMessage, @((NSInteger)[[NSDate date] timeIntervalSince1970])];
    }
    if (!WWRGMarkGrabbed(hid)) {
        WWRGLog(@"dup hid=%@", hid);
        return;
    }

    NSString *wish = WWRGWishFromItem(item);
    WWRGLog(@"GRAB hid=%@ conv=%@ wish=%@", hid, convName, wish);

    NSInteger delay = WWRGDelayMs();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        @try {
            Class bubbleCls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
            if (!bubbleCls) {
                WWRGLog(@"no bubble class");
                WWRGCancelPending(hid);
                return;
            }
            id bubble = [[bubbleCls alloc] init];
            if ([bubble respondsToSelector:@selector(setMessage:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), wwkMessage);
            } else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)]) {
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), wwkMessage, 0);
            }
            if ([bubble respondsToSelector:@selector(updateData)]) {
                WWRGSafePerformV(bubble, @selector(updateData));
            }
            objc_setAssociatedObject(bubble, "wwrg_hid", hid, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(bubble, "wwrg_conv", convName ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(bubble, "wwrg_wish", wish ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            WWRGTriggerClick(bubble);

            // keep bubble alive briefly
            objc_setAssociatedObject(wwkMessage, "wwrg_bubble_keep", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(wwkMessage, "wwrg_bubble_keep", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
        } @catch (NSException *ex) {
            WWRGLog(@"grab exception %@", ex);
            WWRGCancelPending(hid);
        }
    });
}

static void WWRGHandleWWKMessage(id msg, NSString *convName, NSString *convKey) {
    if (!msg) return;
    // force parse if needed
    if ([msg respondsToSelector:@selector(parseMessage)]) {
        @try { WWRGSafePerformV(msg, @selector(parseMessage)); } @catch (__unused NSException *e) {}
    }
    id item = WWRGSafePerform(msg, @selector(messageItem));
    if (WWRGItemIsHongbao(item)) {
        WWRGTryGrabMessage(msg, convName, convKey);
        return;
    }
    NSArray *items = WWRGSafePerform(msg, @selector(messageItems));
    if ([items isKindOfClass:[NSArray class]]) {
        for (id it in items) {
            if (WWRGItemIsHongbao(it)) {
                WWRGTryGrabMessage(msg, convName, convKey);
                return;
            }
        }
    }
}

// model::Message* -> WWKMessage
static id WWRGWrapModelMessage(void *modelMsgPtr) {
    if (!modelMsgPtr) return nil;
    Class cls = NSClassFromString(@"WWKMessage");
    if (!cls) return nil;
    @try {
        // initWithMessage:observe:  (r^v, B)
        if ([cls instancesRespondToSelector:@selector(initWithMessage:observe:)]) {
            id obj = [cls alloc];
            // pass pointer-to-scoped_refptr-like: many builds take const scoped_refptr& which is pointer-sized value on stack
            // We pass address of local holding the raw ptr (scoped_refptr layout = T*)
            void *tmp = modelMsgPtr;
            id msg = ((id (*)(id, SEL, void *, BOOL))objc_msgSend)(obj, @selector(initWithMessage:observe:), &tmp, NO);
            return msg;
        }
        if ([cls instancesRespondToSelector:@selector(initWithMessage:)]) {
            id obj = [cls alloc];
            void *tmp = modelMsgPtr;
            id msg = ((id (*)(id, SEL, void *))objc_msgSend)(obj, @selector(initWithMessage:), &tmp);
            return msg;
        }
    } @catch (NSException *ex) {
        WWRGLog(@"wrap msg ex %@", ex);
    }
    return nil;
}

typedef struct {
    void **begin;
    void **end;
    void **cap;
} WWRGVector;

static void WWRGConsumeMessageVector(const void *vecPtr, NSString *convName, NSString *convKey) {
    if (!vecPtr) return;
    // try as vector of scoped_refptr (8-byte ptrs)
    const WWRGVector *v = (const WWRGVector *)vecPtr;
    if (!v->begin || !v->end || v->end < v->begin) {
        // maybe single scoped_refptr* / Message*
        void *one = *(void * const *)vecPtr;
        if (one) {
            id msg = WWRGWrapModelMessage(one);
            WWRGHandleWWKMessage(msg, convName, convKey);
        }
        return;
    }
    // sanity: size limit
    ptrdiff_t n = v->end - v->begin;
    if (n <= 0 || n > 200) {
        // fallback single
        void *one = *(void * const *)vecPtr;
        if (one && n <= 0) {
            id msg = WWRGWrapModelMessage(one);
            WWRGHandleWWKMessage(msg, convName, convKey);
        }
        return;
    }
    for (ptrdiff_t i = 0; i < n; i++) {
        void *p = v->begin[i];
        if (!p) continue;
        id msg = WWRGWrapModelMessage(p);
        WWRGHandleWWKMessage(msg, convName, convKey);
    }
}

static NSString *WWRGConvNameFromWrapper(id wrapper) {
    if (!wrapper) return @"";
    id n = WWRGSafePerform(wrapper, @selector(getName));
    if ([n isKindOfClass:[NSString class]]) return n;
    return @"";
}

static NSString *WWRGConvKeyFromWrapper(id wrapper) {
    if (!wrapper) return @"";
    if ([wrapper respondsToSelector:@selector(getId)]) {
        unsigned long long cid = ((unsigned long long (*)(id, SEL))objc_msgSend)(wrapper, @selector(getId));
        if (cid) return [NSString stringWithFormat:@"%llu", cid];
    }
    if ([wrapper respondsToSelector:@selector(getLocalId)]) {
        unsigned long long cid = ((unsigned long long (*)(id, SEL))objc_msgSend)(wrapper, @selector(getLocalId));
        if (cid) return [NSString stringWithFormat:@"L%llu", cid];
    }
    return @"";
}

#pragma mark - Auto open window

static void WWRGAutoOpenWindow(id window) {
    if (!window || !WWRGEnabled()) return;
    NSNumber *done = objc_getAssociatedObject(window, "wwrg_opened");
    if (done.boolValue) return;
    objc_setAssociatedObject(window, "wwrg_opened", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *hid = nil;
    id hidObj = WWRGSafePerform(window, @selector(mHongBaoID));
    if ([hidObj isKindOfClass:[NSString class]]) hid = hidObj;

    WWRGLog(@"auto open window hid=%@ cls=%@", hid, NSStringFromClass([window class]));

    dispatch_async(dispatch_get_main_queue(), ^{
        // small settle delay so UI ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if ([window respondsToSelector:@selector(onOpenBtnClick:)]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(window, @selector(onOpenBtnClick:), nil);
                } else if ([window respondsToSelector:NSSelectorFromString(@"onOpenBtnClick")]) {
                    WWRGSafePerformV(window, NSSelectorFromString(@"onOpenBtnClick"));
                } else {
                    id btn = WWRGSafePerform(window, @selector(mOpenBtn));
                    if ([btn isKindOfClass:[UIButton class]]) {
                        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                    }
                }
            } @catch (NSException *ex) {
                WWRGLog(@"open click ex %@", ex);
            }
        });
    });
}

static void WWRGRecordSuccess(id windowOrResult, long long fenHint) {
    NSString *hid = nil;
    NSString *yuan = nil;
    long long fen = fenHint;

    if ([windowOrResult respondsToSelector:@selector(mHongBaoID)]) {
        id h = WWRGSafePerform(windowOrResult, @selector(mHongBaoID));
        if ([h isKindOfClass:[NSString class]]) hid = h;
    }
    if ([windowOrResult respondsToSelector:@selector(totalAmountYuanStr)]) {
        id y = WWRGSafePerform(windowOrResult, @selector(totalAmountYuanStr));
        if ([y isKindOfClass:[NSString class]]) yuan = y;
    }
    if ([windowOrResult respondsToSelector:@selector(mTotalAmount)]) {
        unsigned long long amt = ((unsigned long long (*)(id, SEL))objc_msgSend)(windowOrResult, @selector(mTotalAmount));
        // mTotalAmount appears to be fen already in many builds; if huge treat as fen
        if (amt > 0 && fen <= 0) fen = (long long)amt;
    }
    if (fen <= 0 && yuan.length) fen = WWRGParseYuanToFen(yuan);
    if (fen <= 0 && [windowOrResult isKindOfClass:[NSString class]]) {
        fen = WWRGParseYuanToFen((NSString *)windowOrResult);
    }

    NSString *conv = objc_getAssociatedObject(windowOrResult, "wwrg_conv") ?: @"";
    NSString *wish = objc_getAssociatedObject(windowOrResult, "wwrg_wish") ?: @"";
    if (hid.length) WWRGFinishGrab(hid);

    if (fen > 0) {
        WWRGLog(@"SUCCESS fen=%lld yuan=%@ hid=%@", fen, yuan, hid);
        WWRGAddHistory(conv, hid, fen, wish);
        dispatch_async(dispatch_get_main_queue(), ^{ WWRGRefreshBallTitle(); });
    } else {
        WWRGLog(@"success but amount unknown hid=%@ yuan=%@", hid, yuan);
        if (hid.length) {
            // still count as one grab with 0 if unknown
            WWRGAddHistory(conv, hid, 0, wish);
        }
    }
}

#pragma mark - Hooks via categories

@interface NSObject (WWRedGrab)
@end

@implementation NSObject (WWRedGrab)

// MARK: Conversation message push
- (void)wwrg_OnAddMessage:(const void *)msgVec end:(BOOL)end inConversation:(void *)conv {
    ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, @selector(wwrg_OnAddMessage:end:inConversation:), msgVec, end, conv);
    if (!WWRGEnabled()) return;
    NSString *name = WWRGConvNameFromWrapper(self);
    NSString *key = WWRGConvKeyFromWrapper(self);
    // only process when end==YES to avoid partial batches, but some paths always end=1
    WWRGConsumeMessageVector(msgVec, name, key);
}

// MARK: Message list controller same selector
- (void)wwrg_list_OnAddMessage:(const void *)msgVec end:(BOOL)end inConversation:(void *)conv {
    ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, @selector(wwrg_list_OnAddMessage:end:inConversation:), msgVec, end, conv);
    if (!WWRGEnabled()) return;
    // list controller may not be wrapper; try get name elsewhere
    WWRGConsumeMessageVector(msgVec, @"", @"");
}

// MARK: Bubble updateData - in-chat path
- (void)wwrg_updateData {
    ((void (*)(id, SEL))objc_msgSend)(self, @selector(wwrg_updateData));
    if (!WWRGEnabled()) return;
    if (![NSStringFromClass([self class]) containsString:@"RedEnvelopesBubble"]) return;

    id msg = WWRGSafePerform(self, @selector(message));
    if (!msg) return;
    id item = WWRGSafePerform(self, @selector(messageItem));
    if (!item) item = WWRGSafePerform(msg, @selector(messageItem));
    if (!WWRGItemIsHongbao(item)) return;

    NSString *hid = WWRGHongbaoIDFromItem(item);
    if (hid.length == 0) return;
    if (!WWRGMarkGrabbed(hid)) return;

    NSString *wish = WWRGWishFromItem(item);
    objc_setAssociatedObject(self, "wwrg_hid", hid, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, "wwrg_wish", wish, OBJC_ASSOCIATION_COPY_NONATOMIC);

    NSInteger delay = WWRGDelayMs();
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        id strong = weakSelf;
        if (!strong) { WWRGCancelPending(hid); return; }
        WWRGLog(@"bubble updateData auto click hid=%@", hid);
        WWRGTriggerClick(strong);
    });
}

// MARK: Open window UI ready
- (void)wwrg_open_updateUIData {
    ((void (*)(id, SEL))objc_msgSend)(self, @selector(wwrg_open_updateUIData));
    if (!WWRGEnabled()) return;
    WWRGAutoOpenWindow(self);
}

- (void)wwrg_open_updateUIDataB:(BOOL)flag {
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self, @selector(wwrg_open_updateUIDataB:), flag);
    if (!WWRGEnabled()) return;
    WWRGAutoOpenWindow(self);
}

- (void)wwrg_startOpenHongbaoAnimation {
    ((void (*)(id, SEL))objc_msgSend)(self, @selector(wwrg_startOpenHongbaoAnimation));
    // animation start often means already unwrapping
}

- (void)wwrg_onOpenBtnClick:(id)sender {
    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(wwrg_onOpenBtnClick:), sender);
}

// MARK: Result window
- (void)wwrg_result_updateUIData:(id)arg {
    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(wwrg_result_updateUIData:), arg);
    if (!WWRGEnabled()) return;
    long long fen = 0;
    if ([self respondsToSelector:@selector(mTotalAmount)]) {
        fen = (long long)((unsigned long long (*)(id, SEL))objc_msgSend)(self, @selector(mTotalAmount));
    }
    WWRGRecordSuccess(self, fen);
    // close quickly
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self respondsToSelector:@selector(_closeRedEnvWindow)]) {
            WWRGSafePerformV(self, @selector(_closeRedEnvWindow));
        }
    });
}

// MARK: Mgr success
- (void)wwrg_didOpenRedEvnSuc:(id)arg {
    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(wwrg_didOpenRedEvnSuc:), arg);
    WWRGLog(@"didOpenRedEvnSuc %@", arg);
    long long fen = 0;
    if ([arg isKindOfClass:[NSString class]]) fen = WWRGParseYuanToFen(arg);
    else if ([arg respondsToSelector:@selector(mTotalAmount)]) {
        fen = (long long)((unsigned long long (*)(id, SEL))objc_msgSend)(arg, @selector(mTotalAmount));
    } else if ([arg isKindOfClass:[NSNumber class]]) {
        fen = [(NSNumber *)arg longLongValue];
    }
    WWRGRecordSuccess(arg ?: self, fen);
}

// MARK: openHongBaoWindow - attach openBlock auto
- (void)wwrg_openHongBaoWindow:(const void *)data
                     toVidList:(id)vids
                      hbTicket:(const void *)ticket
                     vidTicket:(int)vidTicket
                          conv:(void *)conv
                           msg:(void *)msg {
    ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *))objc_msgSend)(
        self, @selector(wwrg_openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:),
        data, vids, ticket, vidTicket, conv, msg);
    if (!WWRGEnabled()) return;
    // try grab current window
    id win = nil;
    @try {
        Ivar iv = class_getInstanceVariable([self class], "_mHongBaoWindow");
        if (iv) win = object_getIvar(self, iv);
    } @catch (__unused NSException *e) {}
    if (!win) win = WWRGSafePerform(self, @selector(currentActiveHongbaoWindow));
    if (win) {
        dispatch_async(dispatch_get_main_queue(), ^{ WWRGAutoOpenWindow(win); });
    }
}

- (void)wwrg_openHongBaoWindow2:(const void *)data
                      toVidList:(id)vids
                       hbTicket:(const void *)ticket
                      vidTicket:(int)vidTicket
                           conv:(void *)conv
                            msg:(void *)msg
                      openBlock:(id)openBlock
                    cancelBlock:(id)cancelBlock {
    // force openBlock to auto fire if nil-ish; still call orig with same blocks
    ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *, id, id))objc_msgSend)(
        self, @selector(wwrg_openHongBaoWindow2:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:),
        data, vids, ticket, vidTicket, conv, msg, openBlock, cancelBlock);
    if (!WWRGEnabled()) return;
    id win = nil;
    @try {
        Ivar iv = class_getInstanceVariable([self class], "_mHongBaoWindow");
        if (iv) win = object_getIvar(self, iv);
    } @catch (__unused NSException *e) {}
    if (!win) win = WWRGSafePerform(self, @selector(currentActiveHongbaoWindow));
    if (win) {
        dispatch_async(dispatch_get_main_queue(), ^{ WWRGAutoOpenWindow(win); });
    }
}

// MARK: parse hongbao message path
- (void)wwrg_parseHongBaoMessage:(const void *)m {
    ((void (*)(id, SEL, const void *))objc_msgSend)(self, @selector(wwrg_parseHongBaoMessage:), m);
    if (!WWRGEnabled()) return;
    // self is WWKMessage after parse
    dispatch_async(dispatch_get_main_queue(), ^{
        WWRGHandleWWKMessage(self, @"", @"");
    });
}

- (void)wwrg_parseLishiHongBaoMessage:(const void *)m {
    ((void (*)(id, SEL, const void *))objc_msgSend)(self, @selector(wwrg_parseLishiHongBaoMessage:), m);
    if (!WWRGEnabled()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        WWRGHandleWWKMessage(self, @"", @"");
    });
}

@end

#pragma mark - Floating UI

@interface WWRGPanelController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UISwitch *enableSw;
@property (nonatomic, strong) UISwitch *skipSelfSw;
@property (nonatomic, strong) UISlider *delaySlider;
@property (nonatomic, strong) UILabel *delayLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) UITextField *wlField;
@property (nonatomic, strong) UITableView *wlTable;
@property (nonatomic, strong) UITableView *hisTable;
@property (nonatomic, strong) NSMutableArray<NSString *> *wlData;
@property (nonatomic, strong) NSArray *hisData;
@property (nonatomic, strong) UISegmentedControl *seg;
@end

@implementation WWRGPanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.wlData = [WWRGWhitelist() mutableCopy] ?: [NSMutableArray array];
    self.hisData = [WWRGDefaults() arrayForKey:kCfgHistory] ?: @[];

    CGFloat top = 54;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, self.view.bounds.size.width - 100, 28)];
    title.text = @"WW RedGrab";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(self.view.bounds.size.width - 70, 14, 54, 32);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    // enable row
    UILabel *enL = [self label:@"Auto Grab" y:top];
    [self.view addSubview:enL];
    self.enableSw = [[UISwitch alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 70, top, 51, 31)];
    self.enableSw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.enableSw.on = WWRGEnabled();
    [self.enableSw addTarget:self action:@selector(onEnable:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.enableSw];
    top += 44;

    // delay
    UILabel *dL = [self label:@"Delay" y:top];
    [self.view addSubview:dL];
    self.delayLabel = [[UILabel alloc] initWithFrame:CGRectMake(self.view.bounds.size.width - 90, top, 74, 24)];
    self.delayLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.delayLabel.textColor = UIColor.lightGrayColor;
    self.delayLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.delayLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.delayLabel];
    top += 28;
    self.delaySlider = [[UISlider alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 32, 30)];
    self.delaySlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.delaySlider.minimumValue = 0;
    self.delaySlider.maximumValue = 3000;
    self.delaySlider.value = (float)WWRGDelayMs();
    [self.delaySlider addTarget:self action:@selector(onDelay:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.delaySlider];
    [self refreshDelayLabel];
    top += 40;

    // stats
    self.statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 32, 40)];
    self.statsLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statsLabel.textColor = [UIColor colorWithRed:1 green:0.84 blue:0.2 alpha:1];
    self.statsLabel.font = [UIFont boldSystemFontOfSize:15];
    self.statsLabel.numberOfLines = 2;
    [self.view addSubview:self.statsLabel];
    [self refreshStats];
    top += 48;

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(16, top, 120, 32);
    [reset setTitle:@"Reset Stats" forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1] forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(onResetStats) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:reset];
    top += 40;

    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"Whitelist", @"History"]];
    self.seg.frame = CGRectMake(16, top, self.view.bounds.size.width - 32, 30);
    self.seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.seg.selectedSegmentIndex = 0;
    [self.seg addTarget:self action:@selector(onSeg) forControlEvents:UIControlEventValueChanged];
    if (@available(iOS 13.0, *)) {
        self.seg.selectedSegmentTintColor = [UIColor colorWithRed:0.2 green:0.55 blue:1 alpha:1];
    }
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [self.view addSubview:self.seg];
    top += 40;

    // whitelist input
    self.wlField = [[UITextField alloc] initWithFrame:CGRectMake(16, top, self.view.bounds.size.width - 100, 36)];
    self.wlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.wlField.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    self.wlField.textColor = UIColor.whiteColor;
    self.wlField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"conv name to skip" attributes:@{NSForegroundColorAttributeName:[UIColor grayColor]}];
    self.wlField.layer.cornerRadius = 8;
    self.wlField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 36)];
    self.wlField.leftViewMode = UITextFieldViewModeAlways;
    self.wlField.returnKeyType = UIReturnKeyDone;
    self.wlField.delegate = self;
    [self.view addSubview:self.wlField];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(self.view.bounds.size.width - 76, top, 60, 36);
    add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"Add" forState:UIControlStateNormal];
    [add setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    add.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:1 alpha:1];
    add.layer.cornerRadius = 8;
    [add addTarget:self action:@selector(onAddWL) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add];
    top += 48;

    CGFloat tableH = self.view.bounds.size.height - top - 20;
    if (tableH < 120) tableH = 120;

    self.wlTable = [[UITableView alloc] initWithFrame:CGRectMake(0, top, self.view.bounds.size.width, tableH) style:UITableViewStylePlain];
    self.wlTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.wlTable.backgroundColor = UIColor.clearColor;
    self.wlTable.delegate = self;
    self.wlTable.dataSource = self;
    self.wlTable.tag = 1;
    [self.view addSubview:self.wlTable];

    self.hisTable = [[UITableView alloc] initWithFrame:self.wlTable.frame style:UITableViewStylePlain];
    self.hisTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.hisTable.backgroundColor = UIColor.clearColor;
    self.hisTable.delegate = self;
    self.hisTable.dataSource = self;
    self.hisTable.tag = 2;
    self.hisTable.hidden = YES;
    [self.view addSubview:self.hisTable];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, self.view.bounds.size.height - 18, self.view.bounds.size.width - 32, 14)];
    tip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    tip.text = @"whitelist = do NOT grab";
    tip.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    tip.font = [UIFont systemFontOfSize:11];
    [self.view addSubview:tip];
}

- (UILabel *)label:(NSString *)t y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 160, 28)];
    l.text = t;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:16];
    return l;
}

- (void)refreshDelayLabel {
    self.delayLabel.text = [NSString stringWithFormat:@"%ldms", (long)self.delaySlider.value];
}

- (void)refreshStats {
    self.statsLabel.text = [NSString stringWithFormat:@"Total ¥%@   Count %ld",
                            WWRGMoneyStr(WWRGTotalFen()), (long)WWRGGrabCount()];
}

- (void)onEnable:(UISwitch *)sw {
    [WWRGDefaults() setBool:sw.on forKey:kCfgEnabled];
    [WWRGDefaults() synchronize];
    WWRGRefreshBallTitle();
}

- (void)onDelay:(UISlider *)s {
    [WWRGDefaults() setInteger:(NSInteger)s.value forKey:kCfgDelayMs];
    [WWRGDefaults() synchronize];
    [self refreshDelayLabel];
}

- (void)onResetStats {
    [WWRGDefaults() setInteger:0 forKey:kCfgTotalFen];
    [WWRGDefaults() setInteger:0 forKey:kCfgGrabCount];
    [WWRGDefaults() setObject:@[] forKey:kCfgHistory];
    [WWRGDefaults() synchronize];
    self.hisData = @[];
    [self.hisTable reloadData];
    [self refreshStats];
    WWRGRefreshBallTitle();
}

- (void)onAddWL {
    NSString *t = [self.wlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return;
    if (![self.wlData containsObject:t]) {
        [self.wlData addObject:t];
        WWRGSetWhitelist(self.wlData);
        [self.wlTable reloadData];
    }
    self.wlField.text = @"";
    [self.wlField resignFirstResponder];
}

- (void)onSeg {
    BOOL wl = self.seg.selectedSegmentIndex == 0;
    self.wlTable.hidden = !wl;
    self.hisTable.hidden = wl;
    self.wlField.hidden = !wl;
    if (!wl) {
        self.hisData = [WWRGDefaults() arrayForKey:kCfgHistory] ?: @[];
        [self.hisTable reloadData];
    }
}

- (void)onClose {
    gPanelWin.hidden = YES;
    gPanelWin = nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self onAddWL];
    return YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView.tag == 1) return self.wlData.count;
    return self.hisData.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"c";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = UIColor.clearColor;
        cell.textLabel.textColor = UIColor.whiteColor;
        cell.detailTextLabel.textColor = UIColor.lightGrayColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (tableView.tag == 1) {
        cell.textLabel.text = self.wlData[indexPath.row];
        cell.detailTextLabel.text = @"skip";
    } else {
        NSDictionary *it = self.hisData[indexPath.row];
        long long fen = [it[@"fen"] longLongValue];
        cell.textLabel.text = [NSString stringWithFormat:@"¥%@  %@", WWRGMoneyStr(fen), it[@"conv"] ?: @""];
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[it[@"t"] doubleValue]];
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"MM-dd HH:mm:ss";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", [f stringFromDate:d], it[@"wish"] ?: @""];
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.tag == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.tag != 1 || editingStyle != UITableViewCellEditingStyleDelete) return;
    [self.wlData removeObjectAtIndex:indexPath.row];
    WWRGSetWhitelist(self.wlData);
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return tableView.tag == 1 ? 44 : 56;
}

@end

static void WWRGRefreshBallTitle(void) {
    if (!gBall) return;
    BOOL on = WWRGEnabled();
    NSString *t = on ? [NSString stringWithFormat:@"¥%@", WWRGMoneyStr(WWRGTotalFen())] : @"OFF";
    [gBall setTitle:t forState:UIControlStateNormal];
    gBall.backgroundColor = on ? [UIColor colorWithRed:0.90 green:0.22 blue:0.21 alpha:0.92]
                               : [UIColor colorWithWhite:0.35 alpha:0.90];
}

static void WWRGShowPanel(void) {
    if (gPanelWin) {
        gPanelWin.hidden = NO;
        return;
    }
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(sb.size.width - 24, 380);
    CGFloat h = MIN(sb.size.height * 0.72, 620);
    gPanelWin = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width - w)/2, (sb.size.height - h)/2, w, h)];
    gPanelWin.windowLevel = UIWindowLevelAlert + 10;
    gPanelWin.backgroundColor = UIColor.clearColor;
    gPanelWin.layer.cornerRadius = 14;
    gPanelWin.clipsToBounds = YES;
    gPanelWin.rootViewController = [WWRGPanelController new];
    gPanelWin.hidden = NO;
}

static void WWRGBallDrag(UIPanGestureRecognizer *pan) {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGRect b = [UIScreen mainScreen].bounds;
        CGFloat x = v.center.x < b.size.width/2 ? 30 : b.size.width - 30;
        CGFloat y = MIN(MAX(v.center.y, 80), b.size.height - 80);
        [UIView animateWithDuration:0.2 animations:^{ v.center = CGPointMake(x, y); }];
        [WWRGDefaults() setDouble:x forKey:kCfgBallX];
        [WWRGDefaults() setDouble:y forKey:kCfgBallY];
        [WWRGDefaults() synchronize];
    }
}

static void WWRGEnsureUI(void) {
    if (gUIReady) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gUIReady) return;
        UIWindow *key = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (sc.activationState != UISceneActivationStateForegroundActive) continue;
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { key = w; break; }
                }
                if (!key && ((UIWindowScene *)sc).windows.count) key = ((UIWindowScene *)sc).windows.firstObject;
                if (key) break;
            }
        }
        if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            key = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        }
        if (!key) return;

        CGRect b = key.bounds;
        CGFloat x = [WWRGDefaults() doubleForKey:kCfgBallX];
        CGFloat y = [WWRGDefaults() doubleForKey:kCfgBallY];
        if (x < 10 || y < 10) { x = b.size.width - 30; y = b.size.height * 0.55; }

        gBall = [UIButton buttonWithType:UIButtonTypeCustom];
        gBall.frame = CGRectMake(0, 0, 56, 56);
        gBall.center = CGPointMake(x, y);
        gBall.layer.cornerRadius = 28;
        gBall.layer.masksToBounds = YES;
        gBall.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        gBall.titleLabel.adjustsFontSizeToFitWidth = YES;
        gBall.titleLabel.numberOfLines = 2;
        gBall.titleLabel.textAlignment = NSTextAlignmentCenter;
        [gBall setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBall.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        gBall.layer.borderWidth = 1;

        Class dragCls = NSClassFromString(@"WWRGDragProxy");
        if (!dragCls) {
            dragCls = objc_allocateClassPair([NSObject class], "WWRGDragProxy", 0);
            IMP dragIMP = imp_implementationWithBlock(^(id _self, UIPanGestureRecognizer *p) {
                WWRGBallDrag(p);
            });
            class_addMethod(dragCls, NSSelectorFromString(@"onPan:"), dragIMP, "v@:@");
            IMP tapIMP = imp_implementationWithBlock(^(id _self) {
                if (gPanelWin && !gPanelWin.hidden) {
                    gPanelWin.hidden = YES;
                    gPanelWin = nil;
                } else {
                    WWRGShowPanel();
                }
            });
            class_addMethod(dragCls, NSSelectorFromString(@"onTap"), tapIMP, "v@:");
            objc_registerClassPair(dragCls);
        }
        static id dragProxy = nil;
        if (!dragProxy) dragProxy = [dragCls new];
        UIPanGestureRecognizer *pan2 = [[UIPanGestureRecognizer alloc] initWithTarget:dragProxy action:NSSelectorFromString(@"onPan:")];
        [gBall addGestureRecognizer:pan2];
        [gBall addTarget:dragProxy action:NSSelectorFromString(@"onTap") forControlEvents:UIControlEventTouchUpInside];

        [key addSubview:gBall];
        WWRGRefreshBallTitle();
        gUIReady = YES;
        WWRGLog(@"floating ball ready");
    });
}

#pragma mark - Install

static void WWRGInstallHooks(void) {
    gLock = [NSObject new];
    gGrabbedIDs = [NSMutableSet set];
    gPendingIDs = [NSMutableSet set];

    Class wrap = NSClassFromString(@"WWKConversationWrapper");
    if (wrap) {
        // add methods from NSObject category onto target class then exchange
        Method m = class_getInstanceMethod([NSObject class], @selector(wwrg_OnAddMessage:end:inConversation:));
        if (m) {
            class_addMethod(wrap, @selector(wwrg_OnAddMessage:end:inConversation:), method_getImplementation(m), method_getTypeEncoding(m));
            WWRGSwizzle(wrap, @selector(OnAddMessage:end:inConversation:), @selector(wwrg_OnAddMessage:end:inConversation:));
        }
    }

    Class list = NSClassFromString(@"WWKMessageListController");
    if (list) {
        Method m = class_getInstanceMethod([NSObject class], @selector(wwrg_list_OnAddMessage:end:inConversation:));
        if (m) {
            class_addMethod(list, @selector(wwrg_list_OnAddMessage:end:inConversation:), method_getImplementation(m), method_getTypeEncoding(m));
            WWRGSwizzle(list, @selector(OnAddMessage:end:inConversation:), @selector(wwrg_list_OnAddMessage:end:inConversation:));
        }
    }

    Class bubble = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
    if (bubble) {
        Method m = class_getInstanceMethod([NSObject class], @selector(wwrg_updateData));
        if (m) {
            class_addMethod(bubble, @selector(wwrg_updateData), method_getImplementation(m), method_getTypeEncoding(m));
            WWRGSwizzle(bubble, @selector(updateData), @selector(wwrg_updateData));
        }
    }

    Class openWin = NSClassFromString(@"WWRedEnvOpenHongBaoWindow");
    if (openWin) {
        Method m1 = class_getInstanceMethod([NSObject class], @selector(wwrg_open_updateUIData));
        if (m1 && class_getInstanceMethod(openWin, @selector(_updateUIData))) {
            class_addMethod(openWin, @selector(wwrg_open_updateUIData), method_getImplementation(m1), method_getTypeEncoding(m1));
            WWRGSwizzle(openWin, @selector(_updateUIData), @selector(wwrg_open_updateUIData));
        }
        // some builds use _updateUIData:
        Method m2 = class_getInstanceMethod([NSObject class], @selector(wwrg_open_updateUIDataB:));
        if (m2 && class_getInstanceMethod(openWin, @selector(_updateUIData:))) {
            class_addMethod(openWin, @selector(wwrg_open_updateUIDataB:), method_getImplementation(m2), method_getTypeEncoding(m2));
            WWRGSwizzle(openWin, @selector(_updateUIData:), @selector(wwrg_open_updateUIDataB:));
        }
        Method m3 = class_getInstanceMethod([NSObject class], @selector(wwrg_onOpenBtnClick:));
        if (m3 && class_getInstanceMethod(openWin, @selector(onOpenBtnClick:))) {
            class_addMethod(openWin, @selector(wwrg_onOpenBtnClick:), method_getImplementation(m3), method_getTypeEncoding(m3));
            WWRGSwizzle(openWin, @selector(onOpenBtnClick:), @selector(wwrg_onOpenBtnClick:));
        }
    }

    Class resultWin = NSClassFromString(@"WWRedEnvOpenResultWindow");
    if (resultWin) {
        Method m = class_getInstanceMethod([NSObject class], @selector(wwrg_result_updateUIData:));
        if (m && class_getInstanceMethod(resultWin, @selector(_updateUIData:))) {
            class_addMethod(resultWin, @selector(wwrg_result_updateUIData:), method_getImplementation(m), method_getTypeEncoding(m));
            WWRGSwizzle(resultWin, @selector(_updateUIData:), @selector(wwrg_result_updateUIData:));
        }
    }

    Class mgr = NSClassFromString(@"WWRedEnvelopesMgr");
    if (mgr) {
        Method m = class_getInstanceMethod([NSObject class], @selector(wwrg_didOpenRedEvnSuc:));
        if (m && class_getInstanceMethod(mgr, @selector(didOpenRedEvnSuc:))) {
            class_addMethod(mgr, @selector(wwrg_didOpenRedEvnSuc:), method_getImplementation(m), method_getTypeEncoding(m));
            WWRGSwizzle(mgr, @selector(didOpenRedEvnSuc:), @selector(wwrg_didOpenRedEvnSuc:));
        }
        Method m2 = class_getInstanceMethod([NSObject class], @selector(wwrg_openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:));
        SEL s2 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:);
        if (m2 && class_getInstanceMethod(mgr, s2)) {
            class_addMethod(mgr, @selector(wwrg_openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:), method_getImplementation(m2), method_getTypeEncoding(m2));
            WWRGSwizzle(mgr, s2, @selector(wwrg_openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:));
        }
        Method m3 = class_getInstanceMethod([NSObject class], @selector(wwrg_openHongBaoWindow2:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:));
        SEL s3 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:);
        if (m3 && class_getInstanceMethod(mgr, s3)) {
            class_addMethod(mgr, @selector(wwrg_openHongBaoWindow2:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:), method_getImplementation(m3), method_getTypeEncoding(m3));
            WWRGSwizzle(mgr, s3, @selector(wwrg_openHongBaoWindow2:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:));
        }
    }

    Class wmsg = NSClassFromString(@"WWKMessage");
    if (wmsg) {
        Method m = class_getInstanceMethod([NSObject class], @selector(wwrg_parseHongBaoMessage:));
        SEL s = @selector(p_parseHongBaoMessage:);
        if (m && class_getInstanceMethod(wmsg, s)) {
            class_addMethod(wmsg, @selector(wwrg_parseHongBaoMessage:), method_getImplementation(m), method_getTypeEncoding(m));
            WWRGSwizzle(wmsg, s, @selector(wwrg_parseHongBaoMessage:));
        }
        Method m2 = class_getInstanceMethod([NSObject class], @selector(wwrg_parseLishiHongBaoMessage:));
        SEL s2 = @selector(p_parseLishiHongBaoMessage:);
        if (m2 && class_getInstanceMethod(wmsg, s2)) {
            class_addMethod(wmsg, @selector(wwrg_parseLishiHongBaoMessage:), method_getImplementation(m2), method_getTypeEncoding(m2));
            WWRGSwizzle(wmsg, s2, @selector(wwrg_parseLishiHongBaoMessage:));
        }
    }

    WWRGLog(@"hooks installed. enabled=%d delay=%ld", WWRGEnabled(), (long)WWRGDelayMs());
}

#pragma mark - Constructor

__attribute__((constructor))
static void WWRGInit(void) {
    @autoreleasepool {
        WWRGLog(@"loaded into %@", [NSBundle mainBundle].bundleIdentifier);
        // delay hook install a bit so objc classes ready
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGInstallHooks();
        });
        // UI after app window up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGEnsureUI();
        });
        // retry UI
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gUIReady) WWRGEnsureUI();
        });

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            if (!gUIReady) WWRGEnsureUI();
            else if (gBall && !gBall.superview) {
                gUIReady = NO;
                WWRGEnsureUI();
            }
        }];
    }
}
