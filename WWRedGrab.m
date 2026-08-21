#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - Keys

static NSString * const kCfgEnabled   = @"wwrg_enabled";
static NSString * const kCfgDelayMs   = @"wwrg_delay_ms";
static NSString * const kCfgWhitelist = @"wwrg_whitelist";
static NSString * const kCfgTotalFen  = @"wwrg_total_fen";
static NSString * const kCfgGrabCount = @"wwrg_grab_count";
static NSString * const kCfgHistory   = @"wwrg_history";
static NSString * const kCfgBallX     = @"wwrg_ball_x";
static NSString * const kCfgBallY     = @"wwrg_ball_y";

#pragma mark - State

static UIButton *gBall = nil;
static UIWindow *gPanelWin = nil;
static NSMutableSet *gGrabbedIDs = nil;
static NSMutableSet *gPendingIDs = nil;
static NSMutableSet *gCountedHIDs = nil;
static NSObject *gLock = nil;
static BOOL gUIReady = NO;
static BOOL gSilent = YES; // always silent grab, no UI popup

#pragma mark - Log / defaults

static void WWRGLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void WWRGLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WWRedGrab] %@", s);
}

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }

static BOOL WWRGEnabled(void) {
    if (![D() objectForKey:kCfgEnabled]) return YES;
    return [D() boolForKey:kCfgEnabled];
}
static NSInteger WWRGDelayMs(void) {
    NSInteger v = [D() integerForKey:kCfgDelayMs];
    if (v < 0) v = 0; if (v > 5000) v = 5000; return v;
}
static NSArray<NSString *> *WWRGWhitelist(void) {
    return [D() arrayForKey:kCfgWhitelist] ?: @[];
}
static void WWRGSetWhitelist(NSArray *a) {
    [D() setObject:(a ?: @[]) forKey:kCfgWhitelist]; [D() synchronize];
}
static long long WWRGTotalFen(void) { return (long long)[D() integerForKey:kCfgTotalFen]; }
static NSInteger WWRGGrabCount(void) { return [D() integerForKey:kCfgGrabCount]; }
static NSString *WWRGMoneyStr(long long fen) {
    return [NSString stringWithFormat:@"%.2f", fen / 100.0];
}

static BOOL WWRGIsWhitelisted(NSString *name) {
    if (name.length == 0) return NO;
    NSString *n = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *w in WWRGWhitelist()) {
        NSString *t = [w stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length == 0) continue;
        if ([n isEqualToString:t] || [n containsString:t] || [t containsString:n]) return YES;
    }
    return NO;
}

static BOOL WWRGMarkPending(NSString *hid) {
    if (hid.length == 0) return NO;
    @synchronized (gLock) {
        if ([gGrabbedIDs containsObject:hid] || [gPendingIDs containsObject:hid]) return NO;
        [gPendingIDs addObject:hid];
        return YES;
    }
}
static void WWRGFinish(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) {
        [gPendingIDs removeObject:hid];
        [gGrabbedIDs addObject:hid];
        if (gGrabbedIDs.count > 600) {
            NSArray *all = gGrabbedIDs.allObjects;
            [gGrabbedIDs removeAllObjects];
            [gGrabbedIDs addObjectsFromArray:[all subarrayWithRange:NSMakeRange(all.count - 250, 250)]];
        }
    }
}
static void WWRGCancelPending(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) { [gPendingIDs removeObject:hid]; }
}

static id WWRGCall(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}
static void WWRGCallV(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return;
    ((void (*)(id, SEL))objc_msgSend)(obj, sel);
}
static unsigned long long WWRGCallQ(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return 0;
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(obj, sel);
}

static long long WWRGParseYuanToFen(NSString *s) {
    if (s.length == 0) return 0;
    NSMutableString *m = [NSMutableString string];
    BOOL dot = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [m appendFormat:@"%C", c];
        else if ((c == '.' || c == 0x3002) && !dot) { [m appendString:@"."]; dot = YES; }
    }
    if (!m.length) return 0;
    return (long long)llround([m doubleValue] * 100.0);
}

static void WWRGRefreshBallTitle(void);

static void WWRGAddSuccess(NSString *conv, NSString *hid, long long fen, NSString *wish) {
    if (hid.length) {
        @synchronized (gLock) {
            if ([gCountedHIDs containsObject:hid]) {
                WWRGLog(@"amount already counted hid=%@", hid);
                WWRGFinish(hid);
                return;
            }
            [gCountedHIDs addObject:hid];
        }
        WWRGFinish(hid);
    }
    if (fen < 0) fen = 0;

    NSMutableArray *arr = [[D() arrayForKey:kCfgHistory] mutableCopy] ?: [NSMutableArray array];
    [arr insertObject:@{
        @"t": @([[NSDate date] timeIntervalSince1970]),
        @"conv": conv ?: @"",
        @"hid": hid ?: @"",
        @"fen": @(fen),
        @"wish": wish ?: @""
    } atIndex:0];
    while (arr.count > 120) [arr removeLastObject];
    [D() setObject:arr forKey:kCfgHistory];
    if (fen > 0) {
        [D() setInteger:(NSInteger)(WWRGTotalFen() + fen) forKey:kCfgTotalFen];
        [D() setInteger:WWRGGrabCount() + 1 forKey:kCfgGrabCount];
    } else {
        // still +count if we got a real hid success with unknown amount? no, only when fen>0 or explicit success
        [D() setInteger:WWRGGrabCount() + 1 forKey:kCfgGrabCount];
    }
    [D() synchronize];
    WWRGLog(@"记账 金额分=%lld 元=%@ hid=%@ conv=%@", fen, WWRGMoneyStr(fen), hid, conv);
    dispatch_async(dispatch_get_main_queue(), ^{ WWRGRefreshBallTitle(); });
}

#pragma mark - Swizzle

static void WWRGSwizzleInst(Class cls, SEL orig, SEL nw) {
    if (!cls) return;
    Method om = class_getInstanceMethod(cls, orig);
    Method nm = class_getInstanceMethod(cls, nw);
    if (!om || !nm) {
        WWRGLog(@"swizzle miss %@ %s", cls, sel_getName(orig));
        return;
    }
    if (class_addMethod(cls, orig, method_getImplementation(nm), method_getTypeEncoding(nm))) {
        class_replaceMethod(cls, nw, method_getImplementation(om), method_getTypeEncoding(om));
    } else {
        method_exchangeImplementations(om, nm);
    }
    WWRGLog(@"swizzle ok %@ %s", cls, sel_getName(orig));
}

static void WWRGAddAndSwizzle(Class cls, SEL orig, SEL nw, id block, const char *types) {
    if (!cls || !class_getInstanceMethod(cls, orig)) {
        WWRGLog(@"no method %@ %s", cls, sel_getName(orig));
        return;
    }
    IMP imp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, nw, imp, types)) {
        // already added - replace
        Method m = class_getInstanceMethod(cls, nw);
        if (m) method_setImplementation(m, imp);
    }
    WWRGSwizzleInst(cls, orig, nw);
}

#pragma mark - Silent UI kill

static void WWRGHideView(UIView *v) {
    if (!v) return;
    v.hidden = YES;
    v.alpha = 0;
    v.userInteractionEnabled = NO;
    v.frame = CGRectMake(-5000, -5000, 1, 1);
}

static void WWRGDismissController(UIViewController *vc) {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (vc.presentingViewController) {
                [vc dismissViewControllerAnimated:NO completion:nil];
            } else if (vc.navigationController) {
                NSArray *stack = vc.navigationController.viewControllers;
                if (stack.count > 1 && stack.lastObject == vc) {
                    [vc.navigationController popViewControllerAnimated:NO];
                } else {
                    WWRGHideView(vc.view);
                }
            } else {
                WWRGHideView(vc.view);
            }
        } @catch (__unused NSException *e) {
            WWRGHideView(vc.view);
        }
    });
}

#pragma mark - Core grab

static BOOL WWRGItemIsHB(id item) {
    if (!item) return NO;
    NSString *cn = NSStringFromClass([item class]);
    if ([cn containsString:@"MessageRedEnvelopes"] || [cn containsString:@"LishiRedEnvelopes"]) return YES;
    return class_getInstanceMethod([item class], @selector(hongbaoID)) != NULL;
}

static NSString *WWRGHid(id item) {
    id h = WWRGCall(item, @selector(hongbaoID));
    return [h isKindOfClass:NSString.class] ? h : nil;
}
static NSString *WWRGWish(id item) {
    id w = WWRGCall(item, @selector(wishingWording));
    if ([w isKindOfClass:NSString.class]) return w;
    w = WWRGCall(item, @selector(lishingWording));
    return [w isKindOfClass:NSString.class] ? w : @"";
}

static void WWRGClickBubble(id bubble) {
    if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)]) {
        WWRGCallV(bubble, @selector(tony_onClickHongbaoMessage));
        return;
    }
    if ([bubble respondsToSelector:@selector(onClickHongbaoMessage)]) {
        WWRGCallV(bubble, @selector(onClickHongbaoMessage));
    }
}

static void WWRGForceOpenWindow(id win) {
    if (!win) return;
    NSNumber *done = objc_getAssociatedObject(win, "wwrg_opened");
    if (done.boolValue) return;
    objc_setAssociatedObject(win, "wwrg_opened", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // kill UI immediately
    if ([win isKindOfClass:UIView.class]) WWRGHideView((UIView *)win);
    if ([win respondsToSelector:@selector(setHidden:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(win, @selector(setHidden:), YES);
    }

    NSString *hid = nil;
    id h = WWRGCall(win, @selector(mHongBaoID));
    if ([h isKindOfClass:NSString.class]) hid = h;
    WWRGLog(@"静默开包 hid=%@", hid);

    // click open ASAP on main
    void (^doOpen)(void) = ^{
        @try {
            if ([win respondsToSelector:@selector(onOpenBtnClick:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(onOpenBtnClick:), nil);
            } else {
                id btn = WWRGCall(win, @selector(mOpenBtn));
                if ([btn isKindOfClass:UIControl.class]) {
                    [(UIControl *)btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                }
            }
        } @catch (NSException *ex) {
            WWRGLog(@"open ex %@", ex);
        }
    };
    if ([NSThread isMainThread]) doOpen();
    else dispatch_async(dispatch_get_main_queue(), doOpen);
    // retry once in case UI not ready
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSNumber *ok = objc_getAssociatedObject(win, "wwrg_open_retry");
        if (ok.boolValue) return;
        objc_setAssociatedObject(win, "wwrg_open_retry", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // if still has open btn visible path, click again
        doOpen();
    });
}

static void WWRGTryGrabMessage(id wwkMessage, NSString *convName) {
    if (!WWRGEnabled() || !wwkMessage) return;
    if (WWRGIsWhitelisted(convName)) {
        WWRGLog(@"白名单跳过 %@", convName);
        return;
    }

    id item = WWRGCall(wwkMessage, @selector(messageItem));
    if (!WWRGItemIsHB(item)) {
        NSArray *items = WWRGCall(wwkMessage, @selector(messageItems));
        if ([items isKindOfClass:NSArray.class]) {
            for (id it in items) if (WWRGItemIsHB(it)) { item = it; break; }
        }
    }
    if (!WWRGItemIsHB(item)) return;

    NSString *hid = WWRGHid(item);
    if (!hid.length) hid = [NSString stringWithFormat:@"t%p%ld", wwkMessage, (long)time(NULL)];
    if (!WWRGMarkPending(hid)) return;

    NSString *wish = WWRGWish(item);
    WWRGLog(@"准备抢 hid=%@ conv=%@ wish=%@", hid, convName, wish);

    NSInteger delay = WWRGDelayMs();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        @try {
            Class bubbleCls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
            if (!bubbleCls) { WWRGCancelPending(hid); return; }
            id bubble = [[bubbleCls alloc] init];
            if ([bubble respondsToSelector:@selector(setMessage:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), wwkMessage);
            } else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)]) {
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), wwkMessage, 0);
            }
            WWRGCallV(bubble, @selector(updateData));
            objc_setAssociatedObject(bubble, "wwrg_hid", hid, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(bubble, "wwrg_conv", convName ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(bubble, "wwrg_wish", wish ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            // also stamp on message for later amount
            objc_setAssociatedObject(wwkMessage, "wwrg_hid", hid, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(wwkMessage, "wwrg_conv", convName ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(wwkMessage, "wwrg_wish", wish ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);

            WWRGClickBubble(bubble);
            // keep alive
            objc_setAssociatedObject(wwkMessage, "wwrg_keep_bubble", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(wwkMessage, "wwrg_keep_bubble", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
        } @catch (NSException *ex) {
            WWRGLog(@"grab ex %@", ex);
            WWRGCancelPending(hid);
        }
    });
}

static id WWRGWrapMsg(void *modelPtr) {
    if (!modelPtr) return nil;
    Class cls = NSClassFromString(@"WWKMessage");
    if (!cls) return nil;
    @try {
        void *tmp = modelPtr;
        id obj = [cls alloc];
        if ([cls instancesRespondToSelector:@selector(initWithMessage:observe:)]) {
            return ((id (*)(id, SEL, void *, BOOL))objc_msgSend)(obj, @selector(initWithMessage:observe:), &tmp, NO);
        }
        if ([cls instancesRespondToSelector:@selector(initWithMessage:)]) {
            return ((id (*)(id, SEL, void *))objc_msgSend)(obj, @selector(initWithMessage:), &tmp);
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

typedef struct { void **begin; void **end; void **cap; } WWRGVec;

static void WWRGConsumeVec(const void *vecPtr, NSString *convName) {
    if (!vecPtr) return;
    const WWRGVec *v = (const WWRGVec *)vecPtr;
    if (v->begin && v->end && v->end > v->begin) {
        ptrdiff_t n = v->end - v->begin;
        if (n > 0 && n <= 200) {
            for (ptrdiff_t i = 0; i < n; i++) {
                void *p = v->begin[i];
                if (!p) continue;
                id msg = WWRGWrapMsg(p);
                if (!msg) continue;
                WWRGCallV(msg, @selector(parseMessage));
                WWRGTryGrabMessage(msg, convName);
            }
            return;
        }
    }
    void *one = *(void * const *)vecPtr;
    if (one) {
        id msg = WWRGWrapMsg(one);
        if (msg) {
            WWRGCallV(msg, @selector(parseMessage));
            WWRGTryGrabMessage(msg, convName);
        }
    }
}

static NSString *WWRGNameOf(id wrapper) {
    id n = WWRGCall(wrapper, @selector(getName));
    return [n isKindOfClass:NSString.class] ? n : @"";
}

static long long WWRGExtractFenFromObject(id obj) {
    if (!obj) return 0;
    // preferred: self recv amount
    if ([obj respondsToSelector:@selector(mSelfRecvAmount)]) {
        unsigned long long a = WWRGCallQ(obj, @selector(mSelfRecvAmount));
        if (a > 0) return (long long)a;
    }
    if ([obj respondsToSelector:@selector(totalAmountYuanStr)]) {
        id y = WWRGCall(obj, @selector(totalAmountYuanStr));
        if ([y isKindOfClass:NSString.class]) {
            long long f = WWRGParseYuanToFen(y);
            if (f > 0) return f;
        }
    }
    if ([obj respondsToSelector:@selector(mTotalAmount)]) {
        unsigned long long a = WWRGCallQ(obj, @selector(mTotalAmount));
        // open result window mTotalAmount is often self amount after unwrap
        if (a > 0 && a < 100000000ULL) return (long long)a; // < 1e8 fen = 1e6 yuan sanity
    }
    // labels
    if ([obj respondsToSelector:@selector(mWishingLabel)]) {
        // no
    }
    if ([obj isKindOfClass:NSString.class]) return WWRGParseYuanToFen((NSString *)obj);
    if ([obj isKindOfClass:NSNumber.class]) return [(NSNumber *)obj longLongValue];
    return 0;
}

static void WWRGRecordFrom(id obj, NSString *fallbackHid) {
    NSString *hid = fallbackHid;
    id h = WWRGCall(obj, @selector(mHongBaoID));
    if ([h isKindOfClass:NSString.class] && [h length]) hid = h;
    if (!hid.length) hid = objc_getAssociatedObject(obj, "wwrg_hid");

    NSString *conv = objc_getAssociatedObject(obj, "wwrg_conv") ?: @"";
    NSString *wish = objc_getAssociatedObject(obj, "wwrg_wish") ?: @"";
    long long fen = WWRGExtractFenFromObject(obj);
    if (fen <= 0) {
        // try associated amount
        NSNumber *af = objc_getAssociatedObject(obj, "wwrg_fen");
        if (af) fen = af.longLongValue;
    }
    if (fen > 0 || hid.length) {
        WWRGAddSuccess(conv, hid, fen, wish);
    }
}

#pragma mark - Floating UI (Chinese)

@interface WWRGPanelController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UISwitch *enableSw;
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
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    self.wlData = [WWRGWhitelist() mutableCopy] ?: [NSMutableArray array];
    self.hisData = [D() arrayForKey:kCfgHistory] ?: @[];

    CGFloat W = self.view.bounds.size.width;
    CGFloat top = 52;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, W - 100, 30)];
    title.text = @"企业微信秒抢红包";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:18];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(W - 72, 12, 56, 34);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16];
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UILabel *enL = [self lab:@"自动抢红包" y:top];
    [self.view addSubview:enL];
    self.enableSw = [[UISwitch alloc] initWithFrame:CGRectMake(W - 70, top, 51, 31)];
    self.enableSw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.enableSw.on = WWRGEnabled();
    [self.enableSw addTarget:self action:@selector(onEnable:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.enableSw];
    top += 44;

    UILabel *dL = [self lab:@"延迟(毫秒)" y:top];
    [self.view addSubview:dL];
    self.delayLabel = [[UILabel alloc] initWithFrame:CGRectMake(W - 100, top, 84, 24)];
    self.delayLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.delayLabel.textColor = UIColor.lightGrayColor;
    self.delayLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.delayLabel.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.delayLabel];
    top += 26;
    self.delaySlider = [[UISlider alloc] initWithFrame:CGRectMake(16, top, W - 32, 30)];
    self.delaySlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.delaySlider.minimumValue = 0;
    self.delaySlider.maximumValue = 3000;
    self.delaySlider.value = (float)WWRGDelayMs();
    [self.delaySlider addTarget:self action:@selector(onDelay:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.delaySlider];
    [self refreshDelay];
    top += 38;

    self.statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, top, W - 32, 44)];
    self.statsLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.statsLabel.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    self.statsLabel.font = [UIFont boldSystemFontOfSize:16];
    self.statsLabel.numberOfLines = 2;
    [self.view addSubview:self.statsLabel];
    [self refreshStats];
    top += 48;

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(16, top, 100, 32);
    [reset setTitle:@"清空统计" forState:UIControlStateNormal];
    [reset setTitleColor:[UIColor colorWithRed:1 green:0.45 blue:0.4 alpha:1] forState:UIControlStateNormal];
    [reset addTarget:self action:@selector(onReset) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:reset];
    top += 40;

    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"白名单", @"抢包记录"]];
    self.seg.frame = CGRectMake(16, top, W - 32, 32);
    self.seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.seg.selectedSegmentIndex = 0;
    [self.seg addTarget:self action:@selector(onSeg) forControlEvents:UIControlEventValueChanged];
    if (@available(iOS 13.0, *)) self.seg.selectedSegmentTintColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateSelected];
    [self.view addSubview:self.seg];
    top += 42;

    self.wlField = [[UITextField alloc] initWithFrame:CGRectMake(16, top, W - 100, 36)];
    self.wlField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.wlField.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    self.wlField.textColor = UIColor.whiteColor;
    self.wlField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"输入会话名(包含即不抢)" attributes:@{NSForegroundColorAttributeName: UIColor.grayColor}];
    self.wlField.layer.cornerRadius = 8;
    self.wlField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 36)];
    self.wlField.leftViewMode = UITextFieldViewModeAlways;
    self.wlField.returnKeyType = UIReturnKeyDone;
    self.wlField.delegate = self;
    [self.view addSubview:self.wlField];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(W - 76, top, 60, 36);
    add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"添加" forState:UIControlStateNormal];
    [add setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    add.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1];
    add.layer.cornerRadius = 8;
    [add addTarget:self action:@selector(onAdd) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add];
    top += 48;

    CGFloat th = MAX(120, self.view.bounds.size.height - top - 24);
    self.wlTable = [[UITableView alloc] initWithFrame:CGRectMake(0, top, W, th) style:UITableViewStylePlain];
    self.wlTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.wlTable.backgroundColor = UIColor.clearColor;
    self.wlTable.delegate = self; self.wlTable.dataSource = self; self.wlTable.tag = 1;
    [self.view addSubview:self.wlTable];

    self.hisTable = [[UITableView alloc] initWithFrame:self.wlTable.frame style:UITableViewStylePlain];
    self.hisTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.hisTable.backgroundColor = UIColor.clearColor;
    self.hisTable.delegate = self; self.hisTable.dataSource = self; self.hisTable.tag = 2;
    self.hisTable.hidden = YES;
    [self.view addSubview:self.hisTable];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, self.view.bounds.size.height - 20, W - 32, 16)];
    tip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    tip.text = @"白名单=不抢  |  静默秒抢不弹窗";
    tip.textColor = [UIColor colorWithWhite:0.55 alpha:1];
    tip.font = [UIFont systemFontOfSize:11];
    [self.view addSubview:tip];
}

- (UILabel *)lab:(NSString *)t y:(CGFloat)y {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 180, 28)];
    l.text = t; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:16];
    return l;
}
- (void)refreshDelay { self.delayLabel.text = [NSString stringWithFormat:@"%ld 毫秒", (long)self.delaySlider.value]; }
- (void)refreshStats {
    self.statsLabel.text = [NSString stringWithFormat:@"累计金额 ¥%@\n成功次数 %ld 次",
                            WWRGMoneyStr(WWRGTotalFen()), (long)WWRGGrabCount()];
}
- (void)onEnable:(UISwitch *)sw { [D() setBool:sw.on forKey:kCfgEnabled]; [D() synchronize]; WWRGRefreshBallTitle(); }
- (void)onDelay:(UISlider *)s { [D() setInteger:(NSInteger)s.value forKey:kCfgDelayMs]; [D() synchronize]; [self refreshDelay]; }
- (void)onReset {
    [D() setInteger:0 forKey:kCfgTotalFen];
    [D() setInteger:0 forKey:kCfgGrabCount];
    [D() setObject:@[] forKey:kCfgHistory];
    [D() synchronize];
    @synchronized (gLock) { [gCountedHIDs removeAllObjects]; }
    self.hisData = @[];
    [self.hisTable reloadData];
    [self refreshStats];
    WWRGRefreshBallTitle();
}
- (void)onAdd {
    NSString *t = [self.wlField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
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
    if (!wl) { self.hisData = [D() arrayForKey:kCfgHistory] ?: @[]; [self.hisTable reloadData]; }
}
- (void)onClose { gPanelWin.hidden = YES; gPanelWin = nil; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self onAdd]; return YES; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return tv.tag == 1 ? self.wlData.count : self.hisData.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        c.backgroundColor = UIColor.clearColor;
        c.textLabel.textColor = UIColor.whiteColor;
        c.detailTextLabel.textColor = UIColor.lightGrayColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (tv.tag == 1) {
        c.textLabel.text = self.wlData[ip.row];
        c.detailTextLabel.text = @"不抢此会话";
    } else {
        NSDictionary *it = self.hisData[ip.row];
        long long fen = [it[@"fen"] longLongValue];
        c.textLabel.text = [NSString stringWithFormat:@"¥%@  %@", WWRGMoneyStr(fen), it[@"conv"] ?: @""];
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[it[@"t"] doubleValue]];
        NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"MM-dd HH:mm:ss";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", [f stringFromDate:d], it[@"wish"] ?: @""];
    }
    return c;
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return tv.tag == 1; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if (tv.tag != 1 || es != UITableViewCellEditingStyleDelete) return;
    [self.wlData removeObjectAtIndex:ip.row];
    WWRGSetWhitelist(self.wlData);
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip { return @"删除"; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return tv.tag == 1 ? 46 : 58; }
@end

static void WWRGShowPanel(void) {
    if (gPanelWin) { gPanelWin.hidden = NO; return; }
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat w = MIN(sb.size.width - 20, 390);
    CGFloat h = MIN(sb.size.height * 0.75, 640);
    gPanelWin = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width-w)/2, (sb.size.height-h)/2, w, h)];
    gPanelWin.windowLevel = UIWindowLevelAlert + 10;
    gPanelWin.backgroundColor = UIColor.clearColor;
    gPanelWin.layer.cornerRadius = 14;
    gPanelWin.clipsToBounds = YES;
    gPanelWin.rootViewController = [WWRGPanelController new];
    gPanelWin.hidden = NO;
}

static void WWRGRefreshBallTitle(void) {
    if (!gBall) return;
    BOOL on = WWRGEnabled();
    NSString *t = on ? [NSString stringWithFormat:@"¥%@", WWRGMoneyStr(WWRGTotalFen())] : @"关";
    [gBall setTitle:t forState:UIControlStateNormal];
    gBall.backgroundColor = on ? [UIColor colorWithRed:0.90 green:0.20 blue:0.18 alpha:0.94]
                               : [UIColor colorWithWhite:0.35 alpha:0.92];
}

static void WWRGBallDrag(UIPanGestureRecognizer *pan) {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGRect b = UIScreen.mainScreen.bounds;
        CGFloat x = v.center.x < b.size.width/2 ? 30 : b.size.width - 30;
        CGFloat y = MIN(MAX(v.center.y, 80), b.size.height - 80);
        [UIView animateWithDuration:0.2 animations:^{ v.center = CGPointMake(x, y); }];
        [D() setDouble:x forKey:kCfgBallX]; [D() setDouble:y forKey:kCfgBallY]; [D() synchronize];
    }
}

static void WWRGEnsureUI(void) {
    if (gUIReady) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gUIReady) return;
        UIWindow *key = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                if (sc.activationState != UISceneActivationStateForegroundActive) continue;
                if (![sc isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) { key = w; break; }
                if (!key) key = ((UIWindowScene *)sc).windows.firstObject;
                if (key) break;
            }
        }
        if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            key = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
        }
        if (!key) return;

        CGRect b = key.bounds;
        CGFloat x = [D() doubleForKey:kCfgBallX];
        CGFloat y = [D() doubleForKey:kCfgBallY];
        if (x < 10 || y < 10) { x = b.size.width - 30; y = b.size.height * 0.55; }

        gBall = [UIButton buttonWithType:UIButtonTypeCustom];
        gBall.frame = CGRectMake(0, 0, 58, 58);
        gBall.center = CGPointMake(x, y);
        gBall.layer.cornerRadius = 29;
        gBall.clipsToBounds = YES;
        gBall.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        gBall.titleLabel.adjustsFontSizeToFitWidth = YES;
        gBall.titleLabel.numberOfLines = 2;
        gBall.titleLabel.textAlignment = NSTextAlignmentCenter;
        [gBall setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBall.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        gBall.layer.borderWidth = 1;

        Class dragCls = NSClassFromString(@"WWRGDragProxy");
        if (!dragCls) {
            dragCls = objc_allocateClassPair(NSObject.class, "WWRGDragProxy", 0);
            class_addMethod(dragCls, NSSelectorFromString(@"onPan:"),
                            imp_implementationWithBlock(^(id _s, UIPanGestureRecognizer *p){ WWRGBallDrag(p); }), "v@:@");
            class_addMethod(dragCls, NSSelectorFromString(@"onTap"),
                            imp_implementationWithBlock(^(id _s){
                if (gPanelWin && !gPanelWin.hidden) { gPanelWin.hidden = YES; gPanelWin = nil; }
                else WWRGShowPanel();
            }), "v@:");
            objc_registerClassPair(dragCls);
        }
        static id proxy = nil;
        if (!proxy) proxy = [dragCls new];
        [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:proxy action:NSSelectorFromString(@"onPan:")]];
        [gBall addTarget:proxy action:NSSelectorFromString(@"onTap") forControlEvents:UIControlEventTouchUpInside];

        [key addSubview:gBall];
        WWRGRefreshBallTitle();
        gUIReady = YES;
        WWRGLog(@"悬浮球就绪");
    });
}

#pragma mark - Install hooks

static void WWRGInstall(void) {
    gLock = [NSObject new];
    gGrabbedIDs = [NSMutableSet set];
    gPendingIDs = [NSMutableSet set];
    gCountedHIDs = [NSMutableSet set];

    // 1) new message
    Class wrap = NSClassFromString(@"WWKConversationWrapper");
    if (wrap && class_getInstanceMethod(wrap, @selector(OnAddMessage:end:inConversation:))) {
        SEL nw = NSSelectorFromString(@"wwrg_OnAddMessage:end:inConversation:");
        WWRGAddAndSwizzle(wrap, @selector(OnAddMessage:end:inConversation:), nw,
            ^(id self, const void *vec, BOOL end, void *conv) {
                ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, nw, vec, end, conv);
                if (!WWRGEnabled()) return;
                WWRGConsumeVec(vec, WWRGNameOf(self));
            }, "v@:^vB^v");
    }

    Class list = NSClassFromString(@"WWKMessageListController");
    if (list && class_getInstanceMethod(list, @selector(OnAddMessage:end:inConversation:))) {
        SEL nw = NSSelectorFromString(@"wwrg_list_OnAddMessage:end:inConversation:");
        WWRGAddAndSwizzle(list, @selector(OnAddMessage:end:inConversation:), nw,
            ^(id self, const void *vec, BOOL end, void *conv) {
                ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, nw, vec, end, conv);
                if (!WWRGEnabled()) return;
                WWRGConsumeVec(vec, @"");
            }, "v@:^vB^v");
    }

    // 2) bubble updateData in chat
    Class bubble = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
    if (bubble && class_getInstanceMethod(bubble, @selector(updateData))) {
        SEL nw = NSSelectorFromString(@"wwrg_updateData");
        WWRGAddAndSwizzle(bubble, @selector(updateData), nw, ^(id self) {
            ((void (*)(id, SEL))objc_msgSend)(self, nw);
            if (!WWRGEnabled()) return;
            id msg = WWRGCall(self, @selector(message));
            id item = WWRGCall(self, @selector(messageItem));
            if (!WWRGItemIsHB(item)) item = WWRGCall(msg, @selector(messageItem));
            if (!WWRGItemIsHB(item)) return;
            NSString *hid = WWRGHid(item);
            if (!hid.length) return;
            if (!WWRGMarkPending(hid)) return;
            NSString *wish = WWRGWish(item);
            objc_setAssociatedObject(self, "wwrg_hid", hid, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(self, "wwrg_wish", wish, OBJC_ASSOCIATION_COPY_NONATOMIC);
            NSInteger delay = WWRGDelayMs();
            __weak id ws = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                id s = ws; if (!s) { WWRGCancelPending(hid); return; }
                WWRGLog(@"气泡静默点击 hid=%@", hid);
                WWRGClickBubble(s);
            });
        }, "v@:");
    }

    // 3) open window: hide + auto open (NO UI)
    Class openWin = NSClassFromString(@"WWRedEnvOpenHongBaoWindow");
    if (openWin) {
        // didMoveToWindow / layoutSubviews / _updateUIData
        if (class_getInstanceMethod(openWin, @selector(_updateUIData))) {
            SEL nw = NSSelectorFromString(@"wwrg_open_upd");
            WWRGAddAndSwizzle(openWin, @selector(_updateUIData), nw, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, nw);
                if (!WWRGEnabled()) return;
                if (gSilent) WWRGHideView(self);
                WWRGForceOpenWindow(self);
            }, "v@:");
        }
        if (class_getInstanceMethod(openWin, @selector(_updateUIData:))) {
            SEL nw = NSSelectorFromString(@"wwrg_open_updB:");
            WWRGAddAndSwizzle(openWin, @selector(_updateUIData:), nw, ^(id self, BOOL f) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self, nw, f);
                if (!WWRGEnabled()) return;
                if (gSilent) WWRGHideView(self);
                WWRGForceOpenWindow(self);
            }, "v@:B");
        }
        if (class_getInstanceMethod(openWin, @selector(layoutSubviews))) {
            SEL nw = NSSelectorFromString(@"wwrg_open_layout");
            WWRGAddAndSwizzle(openWin, @selector(layoutSubviews), nw, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, nw);
                if (WWRGEnabled() && gSilent) WWRGHideView(self);
            }, "v@:");
        }
        if (class_getInstanceMethod(openWin, @selector(didMoveToWindow))) {
            SEL nw = NSSelectorFromString(@"wwrg_open_moveWin");
            WWRGAddAndSwizzle(openWin, @selector(didMoveToWindow), nw, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, nw);
                if (!WWRGEnabled()) return;
                if (gSilent) WWRGHideView(self);
                WWRGForceOpenWindow(self);
            }, "v@:");
        }
        // after open success close ASAP
        if (class_getInstanceMethod(openWin, @selector(playOpenSuccessVoice))) {
            SEL nw = NSSelectorFromString(@"wwrg_playSucc");
            WWRGAddAndSwizzle(openWin, @selector(playOpenSuccessVoice), nw, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, nw);
                long long fen = WWRGExtractFenFromObject(self);
                if (fen > 0) WWRGRecordFrom(self, objc_getAssociatedObject(self, "wwrg_hid"));
                if (gSilent) {
                    WWRGHideView(self);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WWRGCallV(self, @selector(_closeRedEnvWindow));
                    });
                }
            }, "v@:");
        }
    }

    // 4) result window - amount + kill UI
    Class resultWin = NSClassFromString(@"WWRedEnvOpenResultWindow");
    if (resultWin) {
        if (class_getInstanceMethod(resultWin, @selector(_updateUIData:))) {
            SEL nw = NSSelectorFromString(@"wwrg_res_upd:");
            WWRGAddAndSwizzle(resultWin, @selector(_updateUIData:), nw, ^(id self, BOOL f) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self, nw, f);
                if (!WWRGEnabled()) return;
                if (gSilent) WWRGHideView(self);
                long long fen = WWRGExtractFenFromObject(self);
                WWRGLog(@"结果窗 amount=%lld yuanStr=%@", fen, WWRGCall(self, @selector(totalAmountYuanStr)));
                WWRGRecordFrom(self, nil);
                dispatch_async(dispatch_get_main_queue(), ^{
                    WWRGCallV(self, @selector(_closeRedEnvWindow));
                    WWRGCallV(self, @selector(closeRedEnvWindowWithFlyAnimate));
                });
            }, "v@:B");
        }
        if (class_getInstanceMethod(resultWin, @selector(layoutSubviews))) {
            SEL nw = NSSelectorFromString(@"wwrg_res_layout");
            WWRGAddAndSwizzle(resultWin, @selector(layoutSubviews), nw, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, nw);
                if (WWRGEnabled() && gSilent) WWRGHideView(self);
            }, "v@:");
        }
    }

    // 5) detail VC - mSelfRecvAmount is the real self amount
    Class detail = NSClassFromString(@"WWRedEnvDetailViewController");
    if (detail) {
        if (class_getInstanceMethod(detail, @selector(setMSelfRecvAmount:))) {
            SEL nw = NSSelectorFromString(@"wwrg_setSelfAmt:");
            WWRGAddAndSwizzle(detail, @selector(setMSelfRecvAmount:), nw, ^(id self, unsigned long long amt) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(self, nw, amt);
                if (!WWRGEnabled()) return;
                WWRGLog(@"详情自己金额分=%llu", amt);
                if (amt > 0) {
                    objc_setAssociatedObject(self, "wwrg_fen", @((long long)amt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    WWRGRecordFrom(self, nil);
                }
                if (gSilent) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WWRGHideView([self view]);
                        WWRGDismissController(self);
                    });
                }
            }, "v@:Q");
        }
        if (class_getInstanceMethod(detail, @selector(viewDidAppear:))) {
            SEL nw = NSSelectorFromString(@"wwrg_detailAppear:");
            WWRGAddAndSwizzle(detail, @selector(viewDidAppear:), nw, ^(id self, BOOL anim) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self, nw, anim);
                if (!WWRGEnabled()) return;
                long long fen = WWRGExtractFenFromObject(self);
                if (fen > 0) WWRGRecordFrom(self, nil);
                if (gSilent) {
                    WWRGHideView([self view]);
                    WWRGDismissController(self);
                }
            }, "v@:B");
        }
        if (class_getInstanceMethod(detail, @selector(viewWillAppear:))) {
            SEL nw = NSSelectorFromString(@"wwrg_detailWillAppear:");
            WWRGAddAndSwizzle(detail, @selector(viewWillAppear:), nw, ^(id self, BOOL anim) {
                if (WWRGEnabled() && gSilent) {
                    // hide before appear
                    UIView *v = [self view];
                    v.alpha = 0; v.hidden = YES;
                }
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self, nw, anim);
            }, "v@:B");
        }
    }

    // 6) header amount
    Class header = NSClassFromString(@"WWRedEnvDetailHeaderCellView");
    if (header && class_getInstanceMethod(header, @selector(setContent:tipsWording:summaryWording:hongbaoType:hongbaoSubType:hongbaoId:amount:wishingWording:showTurnIn:clickTurnIn:))) {
        SEL orig = @selector(setContent:tipsWording:summaryWording:hongbaoType:hongbaoSubType:hongbaoId:amount:wishingWording:showTurnIn:clickTurnIn:);
        SEL nw = NSSelectorFromString(@"wwrg_setContent:tips:sum:type:sub:hid:amount:wish:show:click:");
        // types approximate - use method encoding from orig
        Method om = class_getInstanceMethod(header, orig);
        const char *enc = method_getTypeEncoding(om);
        IMP imp = imp_implementationWithBlock(^(id self, unsigned long long content, id tips, id sum, unsigned int type, unsigned int sub, id hid, unsigned long long amount, id wish, BOOL show, id click) {
            ((void (*)(id, SEL, unsigned long long, id, id, unsigned int, unsigned int, id, unsigned long long, id, BOOL, id))objc_msgSend)(
                self, nw, content, tips, sum, type, sub, hid, amount, wish, show, click);
            if (!WWRGEnabled()) return;
            WWRGLog(@"header amount分=%llu hid=%@", amount, hid);
            if (amount > 0) {
                NSString *hids = [hid isKindOfClass:NSString.class] ? hid : nil;
                WWRGAddSuccess(@"", hids, (long long)amount, [wish isKindOfClass:NSString.class] ? wish : @"");
            }
        });
        class_addMethod(header, nw, imp, enc);
        WWRGSwizzleInst(header, orig, nw);
    }

    // 7) mgr success + open window path
    Class mgr = NSClassFromString(@"WWRedEnvelopesMgr");
    if (mgr) {
        if (class_getInstanceMethod(mgr, @selector(didOpenRedEvnSuc:))) {
            SEL nw = NSSelectorFromString(@"wwrg_didOpen:");
            WWRGAddAndSwizzle(mgr, @selector(didOpenRedEvnSuc:), nw, ^(id self, id arg) {
                ((void (*)(id, SEL, id))objc_msgSend)(self, nw, arg);
                WWRGLog(@"didOpenRedEvnSuc %@", arg);
                long long fen = WWRGExtractFenFromObject(arg);
                if (fen > 0) WWRGAddSuccess(@"", nil, fen, @"");
                else WWRGRecordFrom(arg, nil);
                // force close windows
                if (gSilent) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        WWRGCallV(self, @selector(closeHongBaoWindow));
                        WWRGCallV(self, @selector(closeResultWindow));
                    });
                }
            }, "v@:@");
        }
        // after openHongBaoWindow created, force silent open
        SEL sOpen = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:);
        if (class_getInstanceMethod(mgr, sOpen)) {
            SEL nw = NSSelectorFromString(@"wwrg_openHB:vids:ticket:vt:conv:msg:");
            Method om = class_getInstanceMethod(mgr, sOpen);
            IMP imp = imp_implementationWithBlock(^(id self, const void *data, id vids, const void *ticket, int vt, void *conv, void *msg) {
                ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *))objc_msgSend)(
                    self, nw, data, vids, ticket, vt, conv, msg);
                if (!WWRGEnabled()) return;
                id win = nil;
                Ivar iv = class_getInstanceVariable([self class], "_mHongBaoWindow");
                if (iv) win = object_getIvar(self, iv);
                if (!win) win = WWRGCall(self, @selector(currentActiveHongbaoWindow));
                if (win) {
                    if (gSilent) WWRGHideView(win);
                    dispatch_async(dispatch_get_main_queue(), ^{ WWRGForceOpenWindow(win); });
                }
            });
            class_addMethod(mgr, nw, imp, method_getTypeEncoding(om));
            WWRGSwizzleInst(mgr, sOpen, nw);
        }
        SEL sOpen2 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:);
        if (class_getInstanceMethod(mgr, sOpen2)) {
            SEL nw = NSSelectorFromString(@"wwrg_openHB2:vids:ticket:vt:conv:msg:ob:cb:");
            Method om = class_getInstanceMethod(mgr, sOpen2);
            IMP imp = imp_implementationWithBlock(^(id self, const void *data, id vids, const void *ticket, int vt, void *conv, void *msg, id ob, id cb) {
                ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *, id, id))objc_msgSend)(
                    self, nw, data, vids, ticket, vt, conv, msg, ob, cb);
                if (!WWRGEnabled()) return;
                id win = nil;
                Ivar iv = class_getInstanceVariable([self class], "_mHongBaoWindow");
                if (iv) win = object_getIvar(self, iv);
                if (!win) win = WWRGCall(self, @selector(currentActiveHongbaoWindow));
                if (win) {
                    if (gSilent) WWRGHideView(win);
                    dispatch_async(dispatch_get_main_queue(), ^{ WWRGForceOpenWindow(win); });
                }
            });
            class_addMethod(mgr, nw, imp, method_getTypeEncoding(om));
            WWRGSwizzleInst(mgr, sOpen2, nw);
        }
    }

    // 8) parse path
    Class wmsg = NSClassFromString(@"WWKMessage");
    if (wmsg) {
        if (class_getInstanceMethod(wmsg, @selector(p_parseHongBaoMessage:))) {
            SEL nw = NSSelectorFromString(@"wwrg_parseHB:");
            WWRGAddAndSwizzle(wmsg, @selector(p_parseHongBaoMessage:), nw, ^(id self, const void *m) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, nw, m);
                if (!WWRGEnabled()) return;
                dispatch_async(dispatch_get_main_queue(), ^{ WWRGTryGrabMessage(self, @""); });
            }, "v@:^v");
        }
        if (class_getInstanceMethod(wmsg, @selector(p_parseLishiHongBaoMessage:))) {
            SEL nw = NSSelectorFromString(@"wwrg_parseLishi:");
            WWRGAddAndSwizzle(wmsg, @selector(p_parseLishiHongBaoMessage:), nw, ^(id self, const void *m) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, nw, m);
                if (!WWRGEnabled()) return;
                dispatch_async(dispatch_get_main_queue(), ^{ WWRGTryGrabMessage(self, @""); });
            }, "v@:^v");
        }
    }

    WWRGLog(@"hooks 安装完成 enabled=%d delay=%ld 静默=%d", WWRGEnabled(), (long)WWRGDelayMs(), gSilent);
}

__attribute__((constructor))
static void WWRGInit(void) {
    @autoreleasepool {
        WWRGLog(@"加载 bundle=%@", NSBundle.mainBundle.bundleIdentifier);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGInstall();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGEnsureUI();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gUIReady) WWRGEnsureUI();
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *n) {
            if (!gUIReady) WWRGEnsureUI();
            else if (gBall && !gBall.superview) { gUIReady = NO; WWRGEnsureUI(); }
        }];
    }
}
