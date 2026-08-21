#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

/*
 * WWRedGrab - WeCom protocol-speed red packet grab
 * Path: OnAddMessage -> tony_onClick (Grab) -> openHongBaoWindow openBlock (UnWrap)
 * openBlock is fired immediately, NO window / NO detail UI.
 * Amount: kWWRedEnvRecvInfoChangeNotification + mSelfRecvAmount / didOpenRedEvnSuc
 */

#pragma mark - Keys

static NSString * const kCfgEnabled   = @"wwrg_enabled";
static NSString * const kCfgDelayMs   = @"wwrg_delay_ms";
static NSString * const kCfgWhitelist = @"wwrg_whitelist";
static NSString * const kCfgTotalFen  = @"wwrg_total_fen";
static NSString * const kCfgGrabCount = @"wwrg_grab_count";
static NSString * const kCfgHistory   = @"wwrg_history";
static NSString * const kCfgBallX     = @"wwrg_ball_x";
static NSString * const kCfgBallY     = @"wwrg_ball_y";
static NSString * const kNotiRecvInfo = @"kWWRedEnvRecvInfoChangeNotification";

#pragma mark - State

static UIButton *gBall;
static UIWindow *gPanelWin;
static NSMutableSet *gDoneIDs;
static NSMutableSet *gPendingIDs;
static NSMutableSet *gCountedIDs;
static NSObject *gLock;
static BOOL gUIReady;
static NSString *gLastHid;
static NSString *gLastConv;
static NSString *gLastWish;

#pragma mark - Util

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
    if (v < 0) v = 0; if (v > 3000) v = 3000; return v;
}
static NSArray *WWRGWhitelist(void) { return [D() arrayForKey:kCfgWhitelist] ?: @[]; }
static void WWRGSetWhitelist(NSArray *a) { [D() setObject:a?:@[] forKey:kCfgWhitelist]; [D() synchronize]; }
static long long WWRGTotalFen(void) { return (long long)[D() integerForKey:kCfgTotalFen]; }
static NSInteger WWRGCount(void) { return [D() integerForKey:kCfgGrabCount]; }
static NSString *WWRGYuan(long long fen) { return [NSString stringWithFormat:@"%.2f", fen/100.0]; }

static BOOL WWRGIsWL(NSString *name) {
    if (!name.length) return NO;
    NSString *n = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *w in WWRGWhitelist()) {
        NSString *t = [w stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!t.length) continue;
        if ([n isEqualToString:t] || [n containsString:t] || [t containsString:n]) return YES;
    }
    return NO;
}

static BOOL WWRGBegin(NSString *hid) {
    if (!hid.length) return NO;
    @synchronized (gLock) {
        if ([gDoneIDs containsObject:hid] || [gPendingIDs containsObject:hid]) return NO;
        [gPendingIDs addObject:hid];
        return YES;
    }
}
static void WWRGEnd(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) {
        [gPendingIDs removeObject:hid];
        [gDoneIDs addObject:hid];
        if (gDoneIDs.count > 800) {
            NSArray *a = gDoneIDs.allObjects;
            [gDoneIDs removeAllObjects];
            [gDoneIDs addObjectsFromArray:[a subarrayWithRange:NSMakeRange(a.count-300, 300)]];
        }
    }
}
static void WWRGCancel(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) { [gPendingIDs removeObject:hid]; }
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
            if ([gCountedIDs containsObject:hid]) {
                WWRGEnd(hid);
                return;
            }
            [gCountedIDs addObject:hid];
        }
        WWRGEnd(hid);
    }
    if (fen < 0) fen = 0;
    NSMutableArray *arr = [[D() arrayForKey:kCfgHistory] mutableCopy] ?: [NSMutableArray array];
    [arr insertObject:@{
        @"t": @(NSDate.date.timeIntervalSince1970),
        @"conv": conv ?: @"",
        @"hid": hid ?: @"",
        @"fen": @(fen),
        @"wish": wish ?: @""
    } atIndex:0];
    while (arr.count > 150) [arr removeLastObject];
    [D() setObject:arr forKey:kCfgHistory];
    [D() setInteger:(NSInteger)(WWRGTotalFen() + (fen > 0 ? fen : 0)) forKey:kCfgTotalFen];
    [D() setInteger:WWRGCount() + 1 forKey:kCfgGrabCount];
    [D() synchronize];
    WWRGLog(@"入账 ¥%@ (%lld分) hid=%@ conv=%@", WWRGYuan(fen), fen, hid, conv);
    dispatch_async(dispatch_get_main_queue(), ^{ WWRGRefreshBall(); });
}

#pragma mark - Swizzle helper

static void WWRGSwizzle(Class cls, SEL orig, SEL nw) {
    if (!cls) return;
    Method om = class_getInstanceMethod(cls, orig);
    Method nm = class_getInstanceMethod(cls, nw);
    if (!om || !nm) { WWRGLog(@"swizzle miss %@ %s", cls, sel_getName(orig)); return; }
    if (class_addMethod(cls, orig, method_getImplementation(nm), method_getTypeEncoding(nm))) {
        class_replaceMethod(cls, nw, method_getImplementation(om), method_getTypeEncoding(om));
    } else {
        method_exchangeImplementations(om, nm);
    }
    WWRGLog(@"hook %@ %s", cls, sel_getName(orig));
}

static void WWRGHook(Class cls, SEL orig, SEL nw, id block) {
    if (!cls || !class_getInstanceMethod(cls, orig)) {
        WWRGLog(@"no sel %@ %s", cls, sel_getName(orig));
        return;
    }
    Method om = class_getInstanceMethod(cls, orig);
    IMP imp = imp_implementationWithBlock(block);
    const char *enc = method_getTypeEncoding(om);
    class_addMethod(cls, nw, imp, enc);
    WWRGSwizzle(cls, orig, nw);
}

#pragma mark - Fire openBlock = protocol UnWrap

static void WWRGInvokeBlock(id block) {
    if (!block) return;
    @try {
        // most openBlock are void(^)(void)
        void (^b0)(void) = block;
        b0();
        return;
    } @catch (__unused NSException *e0) {}
    @try {
        void (^b1)(id) = block;
        b1(nil);
        return;
    } @catch (__unused NSException *e1) {}
    @try {
        void (^b2)(BOOL) = block;
        b2(YES);
        return;
    } @catch (__unused NSException *e2) {}
    WWRGLog(@"openBlock 调用失败");
}

static void WWRGProtocolUnWrap(id openBlock, NSString *tag) {
    if (!openBlock) {
        WWRGLog(@"无 openBlock tag=%@", tag);
        return;
    }
    WWRGLog(@"协议拆包 UnWrap via openBlock tag=%@", tag);
    // network ASAP — don't bounce to main if already ok; still safe on main
    if ([NSThread isMainThread]) {
        WWRGInvokeBlock(openBlock);
    } else {
        // protocol send often wants main/logic thread; use main for safety+speed of serial
        dispatch_async(dispatch_get_main_queue(), ^{ WWRGInvokeBlock(openBlock); });
    }
}

#pragma mark - Kill UI

static void WWRGNukeView(id v) {
    if (!v) return;
    if ([v isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)v;
        view.hidden = YES;
        view.alpha = 0;
        view.userInteractionEnabled = NO;
        view.frame = CGRectMake(-8000, -8000, 0, 0);
    }
}

static void WWRGNukeVC(UIViewController *vc) {
    if (!vc) return;
    WWRGNukeView(vc.view);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (vc.presentingViewController) [vc dismissViewControllerAnimated:NO completion:nil];
            else if (vc.navigationController.topViewController == vc)
                [vc.navigationController popViewControllerAnimated:NO];
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - Grab from message (trigger Grab network via tony_onClick)

static BOOL WWRGIsHBItem(id item) {
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

static void WWRGGrabMsg(id msg, NSString *convName) {
    if (!WWRGEnabled() || !msg) return;
    if (WWRGIsWL(convName)) { WWRGLog(@"白名单跳过 %@", convName); return; }

    id item = WWRGCall(msg, @selector(messageItem));
    if (!WWRGIsHBItem(item)) {
        NSArray *items = WWRGCall(msg, @selector(messageItems));
        if ([items isKindOfClass:NSArray.class])
            for (id it in items) if (WWRGIsHBItem(it)) { item = it; break; }
    }
    if (!WWRGIsHBItem(item)) return;

    NSString *hid = WWRGHid(item);
    if (!hid.length) hid = [NSString stringWithFormat:@"t%p%ld", msg, (long)time(NULL)];
    if (!WWRGBegin(hid)) return;

    NSString *wish = WWRGWish(item);
    gLastHid = [hid copy];
    gLastConv = [convName ?: @"" copy];
    gLastWish = [wish ?: @"" copy];
    objc_setAssociatedObject(msg, "wwrg_hid", hid, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(msg, "wwrg_conv", convName ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(msg, "wwrg_wish", wish ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);

    WWRGLog(@"发现红包 协议抢 hid=%@ conv=%@ delay=%ld", hid, convName, (long)WWRGDelayMs());

    void (^go)(void) = ^{
        @try {
            Class bubbleCls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
            if (!bubbleCls) { WWRGCancel(hid); return; }
            id bubble = [[bubbleCls alloc] init];
            if ([bubble respondsToSelector:@selector(setMessage:)])
                ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), msg);
            else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)])
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), msg, 0);
            // skip heavy updateData if possible — tony_onClick reads message
            if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)])
                WWRGCallV(bubble, @selector(tony_onClickHongbaoMessage));
            else if ([bubble respondsToSelector:@selector(onClickHongbaoMessage)])
                WWRGCallV(bubble, @selector(onClickHongbaoMessage));
            // keep bubble until network returns
            objc_setAssociatedObject(msg, "wwrg_keep", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(msg, "wwrg_keep", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
        } @catch (NSException *ex) {
            WWRGLog(@"grab ex %@", ex);
            WWRGCancel(hid);
        }
    };

    NSInteger delay = WWRGDelayMs();
    if (delay <= 0) {
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), go);
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

static void WWRGOnMsgVec(const void *vec, NSString *conv) {
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
                // parse if needed — p_parseHongBaoMessage hook also covers
                WWRGCallV(msg, @selector(parseMessage));
                WWRGGrabMsg(msg, conv);
            }
            return;
        }
    }
    void *one = *(void * const *)vec;
    if (one) {
        id msg = WWRGWrapMsg(one);
        if (msg) {
            WWRGCallV(msg, @selector(parseMessage));
            WWRGGrabMsg(msg, conv);
        }
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

#pragma mark - Panel UI (CN)

@interface WWRGPanelController : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UISwitch *enSw;
@property (nonatomic, strong) UISlider *delay;
@property (nonatomic, strong) UILabel *delayLab;
@property (nonatomic, strong) UILabel *stats;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *wlTable;
@property (nonatomic, strong) UITableView *hisTable;
@property (nonatomic, strong) NSMutableArray *wl;
@property (nonatomic, strong) NSArray *his;
@property (nonatomic, strong) UISegmentedControl *seg;
@end

@implementation WWRGPanelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.97];
    self.wl = [WWRGWhitelist() mutableCopy] ?: [NSMutableArray array];
    self.his = [D() arrayForKey:kCfgHistory] ?: @[];
    CGFloat W = self.view.bounds.size.width;
    CGFloat y = 52;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, W-100, 30)];
    t.text = @"企业微信秒抢红包"; t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:18]; t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];

    UIButton *c = [UIButton buttonWithType:UIButtonTypeSystem];
    c.frame = CGRectMake(W-72, 12, 56, 34); c.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [c setTitle:@"关闭" forState:UIControlStateNormal]; [c setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [c addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:c];

    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 160, 28)];
    el.text = @"自动抢红包"; el.textColor = UIColor.whiteColor; el.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:el];
    self.enSw = [[UISwitch alloc] initWithFrame:CGRectMake(W-70, y, 51, 31)];
    self.enSw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.enSw.on = WWRGEnabled();
    [self.enSw addTarget:self action:@selector(onEn:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.enSw]; y += 44;

    UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 160, 24)];
    dl.text = @"延迟(越低越快)"; dl.textColor = UIColor.whiteColor; dl.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:dl];
    self.delayLab = [[UILabel alloc] initWithFrame:CGRectMake(W-100, y, 84, 24)];
    self.delayLab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.delayLab.textColor = UIColor.lightGrayColor;
    self.delayLab.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.delayLab.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.delayLab]; y += 26;
    self.delay = [[UISlider alloc] initWithFrame:CGRectMake(16, y, W-32, 30)];
    self.delay.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.delay.minimumValue = 0; self.delay.maximumValue = 1500; self.delay.value = (float)WWRGDelayMs();
    [self.delay addTarget:self action:@selector(onDelay:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.delay]; [self refDelay]; y += 36;

    UILabel *tip1 = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W-32, 18)];
    tip1.text = @"协议直拆 · 不弹窗 · 建议延迟 0";
    tip1.textColor = [UIColor colorWithRed:1 green:0.7 blue:0.2 alpha:1];
    tip1.font = [UIFont systemFontOfSize:12]; tip1.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:tip1]; y += 26;

    self.stats = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W-32, 44)];
    self.stats.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.stats.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    self.stats.font = [UIFont boldSystemFontOfSize:16]; self.stats.numberOfLines = 2;
    [self.view addSubview:self.stats]; [self refStats]; y += 48;

    UIButton *rst = [UIButton buttonWithType:UIButtonTypeSystem];
    rst.frame = CGRectMake(16, y, 100, 30);
    [rst setTitle:@"清空统计" forState:UIControlStateNormal];
    [rst setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.35 alpha:1] forState:UIControlStateNormal];
    [rst addTarget:self action:@selector(onRst) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:rst]; y += 38;

    self.seg = [[UISegmentedControl alloc] initWithItems:@[@"白名单", @"抢包记录"]];
    self.seg.frame = CGRectMake(16, y, W-32, 32); self.seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.seg.selectedSegmentIndex = 0;
    [self.seg addTarget:self action:@selector(onSeg) forControlEvents:UIControlEventValueChanged];
    if (@available(iOS 13.0, *)) self.seg.selectedSegmentTintColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
    [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateSelected];
    [self.view addSubview:self.seg]; y += 42;

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(16, y, W-100, 36)];
    self.field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.field.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    self.field.textColor = UIColor.whiteColor;
    self.field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"会话名包含则不抢" attributes:@{NSForegroundColorAttributeName:UIColor.grayColor}];
    self.field.layer.cornerRadius = 8;
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,10,36)];
    self.field.leftViewMode = UITextFieldViewModeAlways;
    self.field.returnKeyType = UIReturnKeyDone; self.field.delegate = self;
    [self.view addSubview:self.field];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(W-76, y, 60, 36); add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"添加" forState:UIControlStateNormal]; [add setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    add.backgroundColor = [UIColor colorWithRed:0.9 green:0.25 blue:0.2 alpha:1]; add.layer.cornerRadius = 8;
    [add addTarget:self action:@selector(onAdd) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add]; y += 48;

    CGFloat th = MAX(120, self.view.bounds.size.height - y - 22);
    self.wlTable = [[UITableView alloc] initWithFrame:CGRectMake(0, y, W, th) style:UITableViewStylePlain];
    self.wlTable.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.wlTable.backgroundColor = UIColor.clearColor; self.wlTable.delegate = self; self.wlTable.dataSource = self; self.wlTable.tag = 1;
    [self.view addSubview:self.wlTable];
    self.hisTable = [[UITableView alloc] initWithFrame:self.wlTable.frame style:UITableViewStylePlain];
    self.hisTable.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.hisTable.backgroundColor = UIColor.clearColor; self.hisTable.delegate = self; self.hisTable.dataSource = self; self.hisTable.tag = 2;
    self.hisTable.hidden = YES; [self.view addSubview:self.hisTable];
}
- (void)refDelay { self.delayLab.text = [NSString stringWithFormat:@"%ldms", (long)self.delay.value]; }
- (void)refStats { self.stats.text = [NSString stringWithFormat:@"累计金额 ¥%@\n成功 %ld 次", WWRGYuan(WWRGTotalFen()), (long)WWRGCount()]; }
- (void)onEn:(UISwitch *)s { [D() setBool:s.on forKey:kCfgEnabled]; [D() synchronize]; WWRGRefreshBall(); }
- (void)onDelay:(UISlider *)s { [D() setInteger:(NSInteger)s.value forKey:kCfgDelayMs]; [D() synchronize]; [self refDelay]; }
- (void)onRst {
    [D() setInteger:0 forKey:kCfgTotalFen]; [D() setInteger:0 forKey:kCfgGrabCount];
    [D() setObject:@[] forKey:kCfgHistory]; [D() synchronize];
    @synchronized (gLock) { [gCountedIDs removeAllObjects]; }
    self.his = @[]; [self.hisTable reloadData]; [self refStats]; WWRGRefreshBall();
}
- (void)onAdd {
    NSString *t = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
    if (![self.wl containsObject:t]) { [self.wl addObject:t]; WWRGSetWhitelist(self.wl); [self.wlTable reloadData]; }
    self.field.text = @""; [self.field resignFirstResponder];
}
- (void)onSeg {
    BOOL w = self.seg.selectedSegmentIndex == 0;
    self.wlTable.hidden = !w; self.hisTable.hidden = w; self.field.hidden = !w;
    if (!w) { self.his = [D() arrayForKey:kCfgHistory] ?: @[]; [self.hisTable reloadData]; }
}
- (void)close { gPanelWin.hidden = YES; gPanelWin = nil; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self onAdd]; return YES; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return tv.tag==1 ? self.wl.count : self.his.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
        c.backgroundColor = UIColor.clearColor; c.textLabel.textColor = UIColor.whiteColor;
        c.detailTextLabel.textColor = UIColor.lightGrayColor; c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (tv.tag == 1) { c.textLabel.text = self.wl[ip.row]; c.detailTextLabel.text = @"不抢"; }
    else {
        NSDictionary *it = self.his[ip.row];
        c.textLabel.text = [NSString stringWithFormat:@"¥%@  %@", WWRGYuan([it[@"fen"] longLongValue]), it[@"conv"]?:@""];
        NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"MM-dd HH:mm:ss";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[it[@"t"] doubleValue]]], it[@"wish"]?:@""];
    }
    return c;
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return tv.tag==1; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if (tv.tag!=1 || es!=UITableViewCellEditingStyleDelete) return;
    [self.wl removeObjectAtIndex:ip.row]; WWRGSetWhitelist(self.wl);
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip { return @"删除"; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return tv.tag==1?46:58; }
@end

static void WWRGShowPanel(void) {
    if (gPanelWin) { gPanelWin.hidden = NO; return; }
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat w = MIN(sb.size.width-20, 390), h = MIN(sb.size.height*0.75, 640);
    gPanelWin = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width-w)/2,(sb.size.height-h)/2,w,h)];
    gPanelWin.windowLevel = UIWindowLevelAlert+10;
    gPanelWin.layer.cornerRadius = 14; gPanelWin.clipsToBounds = YES;
    gPanelWin.rootViewController = [WWRGPanelController new];
    gPanelWin.hidden = NO;
}
static void WWRGRefreshBall(void) {
    if (!gBall) return;
    BOOL on = WWRGEnabled();
    [gBall setTitle:(on ? [NSString stringWithFormat:@"¥%@", WWRGYuan(WWRGTotalFen())] : @"关") forState:UIControlStateNormal];
    gBall.backgroundColor = on ? [UIColor colorWithRed:0.90 green:0.20 blue:0.18 alpha:0.94]
                               : [UIColor colorWithWhite:0.35 alpha:0.92];
}
static void WWRGDrag(UIPanGestureRecognizer *pan) {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGRect b = UIScreen.mainScreen.bounds;
        CGFloat x = v.center.x < b.size.width/2 ? 30 : b.size.width-30;
        CGFloat y = MIN(MAX(v.center.y, 80), b.size.height-80);
        [UIView animateWithDuration:0.18 animations:^{ v.center = CGPointMake(x,y); }];
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
                for (UIWindow *w in ((UIWindowScene *)sc).windows) if (w.isKeyWindow) { key=w; break; }
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
        CGFloat x=[D() doubleForKey:kCfgBallX], y=[D() doubleForKey:kCfgBallY];
        if (x<10||y<10){ x=key.bounds.size.width-30; y=key.bounds.size.height*0.55; }
        gBall = [UIButton buttonWithType:UIButtonTypeCustom];
        gBall.frame = CGRectMake(0,0,58,58); gBall.center=CGPointMake(x,y);
        gBall.layer.cornerRadius=29; gBall.clipsToBounds=YES;
        gBall.titleLabel.font=[UIFont boldSystemFontOfSize:12];
        gBall.titleLabel.adjustsFontSizeToFitWidth=YES; gBall.titleLabel.numberOfLines=2;
        gBall.titleLabel.textAlignment=NSTextAlignmentCenter;
        [gBall setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBall.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.35].CGColor; gBall.layer.borderWidth=1;

        Class cls = NSClassFromString(@"WWRGDragProxy");
        if (!cls) {
            cls = objc_allocateClassPair(NSObject.class, "WWRGDragProxy", 0);
            class_addMethod(cls, NSSelectorFromString(@"onPan:"),
                imp_implementationWithBlock(^(id s, UIPanGestureRecognizer *p){ WWRGDrag(p); }), "v@:@");
            class_addMethod(cls, NSSelectorFromString(@"onTap"),
                imp_implementationWithBlock(^(id s){
                    if (gPanelWin && !gPanelWin.hidden){ gPanelWin.hidden=YES; gPanelWin=nil; }
                    else WWRGShowPanel();
                }), "v@:");
            objc_registerClassPair(cls);
        }
        static id proxy; if (!proxy) proxy = [cls new];
        [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:proxy action:NSSelectorFromString(@"onPan:")]];
        [gBall addTarget:proxy action:NSSelectorFromString(@"onTap") forControlEvents:UIControlEventTouchUpInside];
        [key addSubview:gBall]; WWRGRefreshBall(); gUIReady=YES;
        WWRGLog(@"悬浮球就绪");
    });
}

#pragma mark - Install

static void WWRGInstall(void) {
    gLock = [NSObject new];
    gDoneIDs = [NSMutableSet set];
    gPendingIDs = [NSMutableSet set];
    gCountedIDs = [NSMutableSet set];

    // ---- 1) message push: earliest point ----
    Class wrap = NSClassFromString(@"WWKConversationWrapper");
    if (wrap) {
        SEL o = @selector(OnAddMessage:end:inConversation:);
        SEL n = NSSelectorFromString(@"wwrg_OnAdd:end:conv:");
        WWRGHook(wrap, o, n, ^(id self, const void *vec, BOOL end, void *conv) {
            ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, n, vec, end, conv);
            if (!WWRGEnabled()) return;
            WWRGOnMsgVec(vec, WWRGName(self));
        });
    }
    Class list = NSClassFromString(@"WWKMessageListController");
    if (list) {
        SEL o = @selector(OnAddMessage:end:inConversation:);
        SEL n = NSSelectorFromString(@"wwrg_listOnAdd:end:conv:");
        WWRGHook(list, o, n, ^(id self, const void *vec, BOOL end, void *conv) {
            ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, n, vec, end, conv);
            if (!WWRGEnabled()) return;
            WWRGOnMsgVec(vec, @"");
        });
    }

    // ---- 2) parse path ----
    Class wmsg = NSClassFromString(@"WWKMessage");
    if (wmsg) {
        if (class_getInstanceMethod(wmsg, @selector(p_parseHongBaoMessage:))) {
            SEL n = NSSelectorFromString(@"wwrg_parseHB:");
            WWRGHook(wmsg, @selector(p_parseHongBaoMessage:), n, ^(id self, const void *m) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, n, m);
                if (WWRGEnabled()) WWRGGrabMsg(self, gLastConv ?: @"");
            });
        }
        if (class_getInstanceMethod(wmsg, @selector(p_parseLishiHongBaoMessage:))) {
            SEL n = NSSelectorFromString(@"wwrg_parseLishi:");
            WWRGHook(wmsg, @selector(p_parseLishiHongBaoMessage:), n, ^(id self, const void *m) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, n, m);
                if (WWRGEnabled()) WWRGGrabMsg(self, gLastConv ?: @"");
            });
        }
    }

    // ---- 3) KEY: openHongBaoWindow with openBlock = protocol UnWrap, NO UI ----
    Class mgr = NSClassFromString(@"WWRedEnvelopesMgr");
    if (mgr) {
        SEL o2 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:);
        if (class_getInstanceMethod(mgr, o2)) {
            SEL n = NSSelectorFromString(@"wwrg_openHB2:vids:tk:vt:cv:msg:ob:cb:");
            Method om = class_getInstanceMethod(mgr, o2);
            IMP imp = imp_implementationWithBlock(^(id self, const void *data, id vids, const void *tk, int vt, void *cv, void *msg, id ob, id cb) {
                if (WWRGEnabled() && ob) {
                    // DO NOT create window — fire protocol UnWrap immediately
                    WWRGLog(@"截获 openBlock 直接拆包(协议)");
                    // still set blocks on mgr in case internal needs
                    if ([self respondsToSelector:@selector(setOpenBlock:)])
                        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setOpenBlock:), ob);
                    if ([self respondsToSelector:@selector(setCancelBlock:)])
                        ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setCancelBlock:), cb);
                    WWRGProtocolUnWrap(ob, @"openHB2");
                    return; // skip original UI path entirely
                }
                // fallback original
                ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *, id, id))objc_msgSend)(
                    self, n, data, vids, tk, vt, cv, msg, ob, cb);
            });
            class_addMethod(mgr, n, imp, method_getTypeEncoding(om));
            WWRGSwizzle(mgr, o2, n);
        }

        SEL o1 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:);
        if (class_getInstanceMethod(mgr, o1)) {
            SEL n = NSSelectorFromString(@"wwrg_openHB1:vids:tk:vt:cv:msg:");
            Method om = class_getInstanceMethod(mgr, o1);
            IMP imp = imp_implementationWithBlock(^(id self, const void *data, id vids, const void *tk, int vt, void *cv, void *msg) {
                if (WWRGEnabled()) {
                    // try existing openBlock on mgr first
                    id ob = WWRGCall(self, @selector(openBlock));
                    if (ob) {
                        WWRGLog(@"openHB1 用已有 openBlock 拆包");
                        WWRGProtocolUnWrap(ob, @"openHB1-prop");
                        return;
                    }
                }
                // call original then immediately try steal openBlock / force open hidden
                ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *))objc_msgSend)(
                    self, n, data, vids, tk, vt, cv, msg);
                if (!WWRGEnabled()) return;
                id ob = WWRGCall(self, @selector(openBlock));
                if (ob) {
                    WWRGLog(@"openHB1 创建后 openBlock 拆包");
                    WWRGProtocolUnWrap(ob, @"openHB1-after");
                    WWRGCallV(self, @selector(closeHongBaoWindow));
                    return;
                }
                // last resort: hidden window click
                id win = nil;
                Ivar iv = class_getInstanceVariable([self class], "_mHongBaoWindow");
                if (iv) win = object_getIvar(self, iv);
                if (!win) win = WWRGCall(self, @selector(currentActiveHongbaoWindow));
                if (win) {
                    WWRGNukeView(win);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if ([win respondsToSelector:@selector(onOpenBtnClick:)])
                            ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(onOpenBtnClick:), nil);
                        WWRGCallV(self, @selector(closeHongBaoWindow));
                    });
                }
            });
            class_addMethod(mgr, n, imp, method_getTypeEncoding(om));
            WWRGSwizzle(mgr, o1, n);
        }

        // success callback
        if (class_getInstanceMethod(mgr, @selector(didOpenRedEvnSuc:))) {
            SEL n = NSSelectorFromString(@"wwrg_didOpen:");
            WWRGHook(mgr, @selector(didOpenRedEvnSuc:), n, ^(id self, id arg) {
                ((void (*)(id, SEL, id))objc_msgSend)(self, n, arg);
                long long fen = WWRGFenFrom(arg);
                WWRGLog(@"didOpenRedEvnSuc fen=%lld arg=%@", fen, arg);
                WWRGBook(gLastConv, gLastHid, fen, gLastWish);
                WWRGCallV(self, @selector(closeHongBaoWindow));
                WWRGCallV(self, @selector(closeResultWindow));
            });
        }

        // recv info notification helper
        if (class_getInstanceMethod(mgr, @selector(postRecvInfoChangeNotification:))) {
            SEL n = NSSelectorFromString(@"wwrg_postRecv:");
            WWRGHook(mgr, @selector(postRecvInfoChangeNotification:), n, ^(id self, const void *info) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, n, info);
                WWRGLog(@"RecvInfoChange 通知");
            });
        }
    }

    // ---- 4) if window still created, never show + openBlock/open click ----
    Class openWin = NSClassFromString(@"WWRedEnvOpenHongBaoWindow");
    if (openWin) {
        if (class_getInstanceMethod(openWin, @selector(didMoveToWindow))) {
            SEL n = NSSelectorFromString(@"wwrg_owMove");
            WWRGHook(openWin, @selector(didMoveToWindow), n, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, n);
                if (!WWRGEnabled()) return;
                WWRGNukeView(self);
                // try mgr openBlock
                id mgrInst = WWRGCall(NSClassFromString(@"WWRedEnvelopesMgr"), @selector(shareInstance));
                id ob = WWRGCall(mgrInst, @selector(openBlock));
                if (ob) WWRGProtocolUnWrap(ob, @"win-move");
                else if ([self respondsToSelector:@selector(onOpenBtnClick:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(onOpenBtnClick:), nil);
                WWRGCallV(mgrInst, @selector(closeHongBaoWindow));
            });
        }
        if (class_getInstanceMethod(openWin, @selector(layoutSubviews))) {
            SEL n = NSSelectorFromString(@"wwrg_owLayout");
            WWRGHook(openWin, @selector(layoutSubviews), n, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, n);
                if (WWRGEnabled()) WWRGNukeView(self);
            });
        }
        if (class_getInstanceMethod(openWin, @selector(_updateUIData))) {
            SEL n = NSSelectorFromString(@"wwrg_owUpd");
            WWRGHook(openWin, @selector(_updateUIData), n, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, n);
                if (!WWRGEnabled()) return;
                WWRGNukeView(self);
                id mgrInst = WWRGCall(NSClassFromString(@"WWRedEnvelopesMgr"), @selector(shareInstance));
                id ob = WWRGCall(mgrInst, @selector(openBlock));
                if (ob) WWRGProtocolUnWrap(ob, @"win-upd");
                else if ([self respondsToSelector:@selector(onOpenBtnClick:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(onOpenBtnClick:), nil);
            });
        }
    }

    // ---- 5) result / detail amount + nuke ----
    Class res = NSClassFromString(@"WWRedEnvOpenResultWindow");
    if (res && class_getInstanceMethod(res, @selector(_updateUIData:))) {
        SEL n = NSSelectorFromString(@"wwrg_resUpd:");
        WWRGHook(res, @selector(_updateUIData:), n, ^(id self, BOOL f) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self, n, f);
            if (!WWRGEnabled()) return;
            WWRGNukeView(self);
            long long fen = WWRGFenFrom(self);
            WWRGLog(@"结果窗 fen=%lld", fen);
            NSString *hid = nil;
            id h = WWRGCall(self, @selector(mHongBaoID));
            if ([h isKindOfClass:NSString.class]) hid = h;
            WWRGBook(gLastConv, hid ?: gLastHid, fen, gLastWish);
            WWRGCallV(self, @selector(_closeRedEnvWindow));
        });
    }

    Class detail = NSClassFromString(@"WWRedEnvDetailViewController");
    if (detail) {
        if (class_getInstanceMethod(detail, @selector(setMSelfRecvAmount:))) {
            SEL n = NSSelectorFromString(@"wwrg_setSelfAmt:");
            WWRGHook(detail, @selector(setMSelfRecvAmount:), n, ^(id self, unsigned long long amt) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(self, n, amt);
                if (!WWRGEnabled()) return;
                WWRGLog(@"详情自己金额=%llu分", amt);
                if (amt > 0) {
                    NSString *hid = nil;
                    id h = WWRGCall(self, @selector(mHongBaoID));
                    if ([h isKindOfClass:NSString.class]) hid = h;
                    WWRGBook(gLastConv, hid ?: gLastHid, (long long)amt, gLastWish);
                }
                WWRGNukeVC(self);
            });
        }
        if (class_getInstanceMethod(detail, @selector(viewWillAppear:))) {
            SEL n = NSSelectorFromString(@"wwrg_dWill:");
            WWRGHook(detail, @selector(viewWillAppear:), n, ^(id self, BOOL a) {
                if (WWRGEnabled()) { UIView *v=[self view]; v.alpha=0; v.hidden=YES; }
                ((void (*)(id, SEL, BOOL))objc_msgSend)(self, n, a);
                if (WWRGEnabled()) WWRGNukeVC(self);
            });
        }
    }

    // header amount
    Class header = NSClassFromString(@"WWRedEnvDetailHeaderCellView");
    SEL hset = @selector(setContent:tipsWording:summaryWording:hongbaoType:hongbaoSubType:hongbaoId:amount:wishingWording:showTurnIn:clickTurnIn:);
    if (header && class_getInstanceMethod(header, hset)) {
        SEL n = NSSelectorFromString(@"wwrg_hdr:tips:sum:ty:sub:hid:amt:wish:show:clk:");
        Method om = class_getInstanceMethod(header, hset);
        IMP imp = imp_implementationWithBlock(^(id self, unsigned long long content, id tips, id sum, unsigned int ty, unsigned int sub, id hid, unsigned long long amount, id wish, BOOL show, id clk) {
            ((void (*)(id, SEL, unsigned long long, id, id, unsigned int, unsigned int, id, unsigned long long, id, BOOL, id))objc_msgSend)(
                self, n, content, tips, sum, ty, sub, hid, amount, wish, show, clk);
            if (!WWRGEnabled()) return;
            if (amount > 0) {
                WWRGLog(@"header金额=%llu hid=%@", amount, hid);
                WWRGBook(gLastConv,
                         [hid isKindOfClass:NSString.class]?hid:gLastHid,
                         (long long)amount,
                         [wish isKindOfClass:NSString.class]?wish:gLastWish);
            }
        });
        class_addMethod(header, n, imp, method_getTypeEncoding(om));
        WWRGSwizzle(header, hset, n);
    }

    // ---- 6) notification amount ----
    [[NSNotificationCenter defaultCenter] addObserverForName:kNotiRecvInfo
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (!WWRGEnabled()) return;
        WWRGLog(@"收到 RecvInfo 通知 %@", note.userInfo);
        // try parse via mgr
        id mgrInst = WWRGCall(NSClassFromString(@"WWRedEnvelopesMgr"), @selector(shareInstance));
        // userInfo may hold amount strings — scan
        NSDictionary *ui = note.userInfo;
        if ([ui isKindOfClass:NSDictionary.class]) {
            for (id v in ui.allValues) {
                long long fen = WWRGFenFrom(v);
                if (fen > 0) { WWRGBook(gLastConv, gLastHid, fen, gLastWish); return; }
                if ([v isKindOfClass:NSString.class]) {
                    long long f = WWRGParseFen(v);
                    if (f > 0) { WWRGBook(gLastConv, gLastHid, f, gLastWish); return; }
                }
            }
        }
        (void)mgrInst;
    }];

    // bubble in-chat (backup if already viewing)
    Class bubble = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
    if (bubble && class_getInstanceMethod(bubble, @selector(updateData))) {
        SEL n = NSSelectorFromString(@"wwrg_bUpd");
        WWRGHook(bubble, @selector(updateData), n, ^(id self) {
            ((void (*)(id, SEL))objc_msgSend)(self, n);
            if (!WWRGEnabled()) return;
            id msg = WWRGCall(self, @selector(message));
            if (msg) WWRGGrabMsg(msg, @"");
        });
    }

    WWRGLog(@"安装完成 协议直拆模式 enabled=%d delay=%ld", WWRGEnabled(), (long)WWRGDelayMs());
}

__attribute__((constructor))
static void WWRGInit(void) {
    @autoreleasepool {
        WWRGLog(@"加载 %@", NSBundle.mainBundle.bundleIdentifier);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGInstall();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WWRGEnsureUI();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gUIReady) WWRGEnsureUI();
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *n) {
            if (!gUIReady) WWRGEnsureUI();
            else if (gBall && !gBall.superview) { gUIReady=NO; WWRGEnsureUI(); }
        }];
    }
}
