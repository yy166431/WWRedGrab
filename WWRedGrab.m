#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <os/lock.h>

/*
 * WWRedGrab — pure protocol silent grab (WeCom iOS)
 *
 * Verified chain (Frida capture, no C-prologue hooks):
 *   OnAddMessage / bubble
 *     -> tony_onClickHongbaoMessage          // internal SendGrab
 *     -> openHongBaoWindow(data, vids, ticket, 0, conv, msg)
 *        hbTicket = *(char**)a4  // 80-hex string
 *     -> onOpenBtnClick:                    // SendUnWrap
 *     -> setMSelfRecvAmount:                // fen
 *     -> didOpenRedEvnSuc:
 *
 * Strategy:
 *   1) Detect HB message ASAP
 *   2) Fire tony_onClick (Grab) with delay 0
 *   3) Intercept openHongBaoWindow → build OFFSCREEN window → onOpenBtnClick → kill UI
 *   4) Never depend on openBlock (often NULL)
 */

#pragma mark - Config

static NSString * const kEn   = @"wwrg_enabled";
static NSString * const kDly  = @"wwrg_delay_ms";
static NSString * const kWL   = @"wwrg_whitelist";
static NSString * const kFen  = @"wwrg_total_fen";
static NSString * const kCnt  = @"wwrg_grab_count";
static NSString * const kHis  = @"wwrg_history";
static NSString * const kBX   = @"wwrg_ball_x";
static NSString * const kBY   = @"wwrg_ball_y";

#pragma mark - State

static UIButton *gBall;
static UIWindow *gPanel;
static BOOL gUIReady;
static NSObject *gLock;
static NSMutableSet *gDone;     // hongbaoID done
static NSMutableSet *gPending;
static NSMutableSet *gAmtDone;  // amount booked
static NSString *gLastHid;
static NSString *gLastConv;
static NSString *gLastWish;
static NSString *gLastTicket;

@interface WWRedGrabKeep : NSObject @end
@implementation WWRedGrabKeep @end

#pragma mark - Utils

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSLog(@"[WWRedGrab] %@", [[NSString alloc] initWithFormat:fmt arguments:ap]);
    va_end(ap);
}

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static BOOL On(void) {
    if (![D() objectForKey:kEn]) return YES;
    return [D() boolForKey:kEn];
}
static NSInteger DelayMs(void) {
    NSInteger v = [D() integerForKey:kDly];
    if (v < 0) v = 0; if (v > 2000) v = 2000; return v;
}
static NSArray *WL(void) { return [D() arrayForKey:kWL] ?: @[]; }
static void SetWL(NSArray *a) { [D() setObject:a ?: @[] forKey:kWL]; [D() synchronize]; }
static long long TotalFen(void) { return (long long)[D() integerForKey:kFen]; }
static NSInteger GrabCnt(void) { return [D() integerForKey:kCnt]; }
static NSString *Yuan(long long fen) { return [NSString stringWithFormat:@"%.2f", fen / 100.0]; }

static BOOL IsWL(NSString *name) {
    if (name.length == 0) return NO;
    NSString *n = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *w in WL()) {
        NSString *t = [w stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length && ([n isEqualToString:t] || [n containsString:t] || [t containsString:n])) return YES;
    }
    return NO;
}

static BOOL Begin(NSString *hid) {
    if (hid.length == 0) return NO;
    @synchronized (gLock) {
        if ([gDone containsObject:hid] || [gPending containsObject:hid]) return NO;
        [gPending addObject:hid];
        return YES;
    }
}
static void End(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) {
        [gPending removeObject:hid];
        [gDone addObject:hid];
    }
}
static void Cancel(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) { [gPending removeObject:hid]; }
}

static id Call(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static void CallV(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return;
    ((void (*)(id, SEL))objc_msgSend)(o, s);
}
static unsigned long long CallQ(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return 0;
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(o, s);
}
static int CallI(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(o, s);
}

static void RefreshBall(void);

static void Book(NSString *conv, NSString *hid, long long fen, NSString *wish) {
    if (hid.length) {
        @synchronized (gLock) {
            if ([gAmtDone containsObject:hid]) { End(hid); return; }
            [gAmtDone addObject:hid];
        }
        End(hid);
    }
    if (fen < 0) fen = 0;
    NSMutableArray *arr = [[D() arrayForKey:kHis] mutableCopy] ?: [NSMutableArray array];
    [arr insertObject:@{
        @"t": @(NSDate.date.timeIntervalSince1970),
        @"conv": conv ?: @"",
        @"hid": hid ?: @"",
        @"fen": @(fen),
        @"wish": wish ?: @""
    } atIndex:0];
    while (arr.count > 150) [arr removeLastObject];
    [D() setObject:arr forKey:kHis];
    if (fen > 0) [D() setInteger:(NSInteger)(TotalFen() + fen) forKey:kFen];
    [D() setInteger:GrabCnt() + 1 forKey:kCnt];
    [D() synchronize];
    L(@"入账 ¥%@ (%lld分) hid=%@ conv=%@", Yuan(fen), fen, hid, conv);
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshBall(); });
}

#pragma mark - Swizzle

static void Swizzle(Class c, SEL o, SEL n) {
    if (!c) return;
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (!om || !nm) { L(@"swizzle miss %@ %s", c, sel_getName(o)); return; }
    if (class_addMethod(c, o, method_getImplementation(nm), method_getTypeEncoding(nm)))
        class_replaceMethod(c, n, method_getImplementation(om), method_getTypeEncoding(om));
    else method_exchangeImplementations(om, nm);
    L(@"hook %@ %s", c, sel_getName(o));
}

static void Hook(Class c, SEL o, SEL n, id block) {
    if (!c || !class_getInstanceMethod(c, o)) { L(@"no %@ %s", c, sel_getName(o)); return; }
    Method om = class_getInstanceMethod(c, o);
    class_addMethod(c, n, imp_implementationWithBlock(block), method_getTypeEncoding(om));
    Swizzle(c, o, n);
}

#pragma mark - Ticket helpers

// hbTicket arg is r^v — observed as pointer whose *value is C string / or NSString / or std::string-like
static NSString *TicketFromPtr(const void *p) {
    if (!p) return nil;
    // try as NSString*
    @try {
        id o = (__bridge id)p;
        if ([o isKindOfClass:NSString.class] && [(NSString *)o length] > 0) return o;
    } @catch (__unused NSException *e) {}
    // try *p as char*
    @try {
        const char *s = *(const char * const *)p;
        if (s && s[0]) {
            NSString *t = [NSString stringWithUTF8String:s];
            if (t.length > 8) return t;
        }
    } @catch (__unused NSException *e) {}
    // try p as char*
    @try {
        const char *s = (const char *)p;
        // sanity printable
        if (s && s[0] && (unsigned char)s[0] >= 0x20) {
            NSString *t = [NSString stringWithUTF8String:s];
            if (t.length > 8 && t.length < 200) return t;
        }
    } @catch (__unused NSException *e) {}
    // std::string SSO
    @try {
        const uint8_t *b = (const uint8_t *)p;
        uint8_t b0 = b[0];
        NSUInteger sz = b0 >> 1;
        if ((b0 & 1) == 0 && sz > 8 && sz < 23) {
            return [[NSString alloc] initWithBytes:b + 1 length:sz encoding:NSUTF8StringEncoding];
        }
        // long string: data ptr often at +8/+16
        for (int off = 8; off <= 16; off += 8) {
            const char *s = *(const char * const *)(b + off);
            if (s && s[0]) {
                NSString *t = [NSString stringWithUTF8String:s];
                if (t.length > 8) return t;
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static void NukeView(UIView *v) {
    if (!v) return;
    v.hidden = YES;
    v.alpha = 0;
    v.userInteractionEnabled = NO;
    v.frame = CGRectMake(-9000, -9000, 1, 1);
}

#pragma mark - Silent UnWrap via offscreen window

static void SilentUnWrap(const void *data, id toVidList, const void *hbTicket, const void *convRef) {
    if (!On()) return;
    Class winCls = NSClassFromString(@"WWRedEnvOpenHongBaoWindow");
    if (!winCls) { L(@"no OpenHongBaoWindow class"); return; }

    NSString *tk = TicketFromPtr(hbTicket);
    if (tk.length) {
        gLastTicket = [tk copy];
        L(@"ticket=%@", tk);
    }

    // Must run on main — UIKit window object (hidden)
    void (^go)(void) = ^{
        @try {
            id win = [winCls alloc];
            SEL ini = @selector(initWithData:toVidList:hbTicket:conv:);
            if (![win respondsToSelector:ini]) {
                L(@"no initWithData:toVidList:hbTicket:conv:");
                return;
            }
            // signature: id, SEL, r^v, id, r^v, scoped_refptr(8)
            // pass conv as the raw 8-byte scoped_refptr value at convRef
            win = ((id (*)(id, SEL, const void *, id, const void *, void *))objc_msgSend)(
                win, ini, data, toVidList, hbTicket, (void *)convRef);
            if (!win) { L(@"win init nil"); return; }

            if ([win isKindOfClass:UIView.class]) NukeView((UIView *)win);
            // force property ticket/id if available
            if (tk.length && [win respondsToSelector:@selector(setMHongbaoTicket:)])
                ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(setMHongbaoTicket:), tk);
            if (gLastHid.length && [win respondsToSelector:@selector(setMHongBaoID:)])
                ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(setMHongBaoID:), gLastHid);

            objc_setAssociatedObject(win, "wwrg_silent", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // UnWrap = onOpenBtnClick
            if ([win respondsToSelector:@selector(onOpenBtnClick:)]) {
                L(@"协议 UnWrap onOpenBtnClick hid=%@", gLastHid);
                ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(onOpenBtnClick:), nil);
            } else {
                L(@"no onOpenBtnClick");
            }

            // keep alive briefly for async network
            objc_setAssociatedObject([WWRedGrabKeep class], "keep", win, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject([WWRedGrabKeep class], "keep", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                id mgr = Call(NSClassFromString(@"WWRedEnvelopesMgr"), @selector(shareInstance));
                CallV(mgr, @selector(closeHongBaoWindow));
                CallV(mgr, @selector(closeResultWindow));
            });
        } @catch (NSException *ex) {
            L(@"SilentUnWrap ex %@", ex);
        }
    };

    if ([NSThread isMainThread]) go();
    else dispatch_async(dispatch_get_main_queue(), go);
}

#pragma mark - Detect & Grab

static BOOL IsHBItem(id item) {
    if (!item) return NO;
    NSString *cn = NSStringFromClass([item class]);
    if ([cn containsString:@"MessageRedEnvelopes"] || [cn containsString:@"LishiRedEnvelopes"]) return YES;
    return [item respondsToSelector:@selector(hongbaoID)];
}

static NSString *HidOf(id item) {
    id h = Call(item, @selector(hongbaoID));
    return [h isKindOfClass:NSString.class] ? h : nil;
}
static NSString *WishOf(id item) {
    id w = Call(item, @selector(wishingWording));
    if ([w isKindOfClass:NSString.class]) return w;
    w = Call(item, @selector(lishingWording));
    return [w isKindOfClass:NSString.class] ? w : @"";
}

static void FireGrab(id wwkMessage, NSString *conv) {
    if (!On() || !wwkMessage) return;
    if (IsWL(conv)) { L(@"白名单跳过 %@", conv); return; }

    id item = Call(wwkMessage, @selector(messageItem));
    if (!IsHBItem(item)) {
        NSArray *items = Call(wwkMessage, @selector(messageItems));
        if ([items isKindOfClass:NSArray.class]) {
            for (id it in items) if (IsHBItem(it)) { item = it; break; }
        }
    }
    if (!IsHBItem(item)) return;

    NSString *hid = HidOf(item);
    if (!hid.length) hid = [NSString stringWithFormat:@"t%p%ld", wwkMessage, (long)time(NULL)];
    if (!Begin(hid)) return;

    NSString *wish = WishOf(item);
    gLastHid = [hid copy];
    gLastConv = [conv ?: @"" copy];
    gLastWish = [wish ?: @"" copy];
    L(@"发现红包 协议抢 hid=%@ type=%@ sub=%@ conv=%@",
      hid, @(CallQ(item, @selector(hongbaoType))), @(CallQ(item, @selector(hongbaoSubType))), conv);

    void (^go)(void) = ^{
        @try {
            Class bcls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
            if (!bcls) { Cancel(hid); return; }
            id bubble = [[bcls alloc] init];
            if ([bubble respondsToSelector:@selector(setMessage:)])
                ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), wwkMessage);
            else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)])
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), wwkMessage, 0);

            // Grab network — tony_onClick
            if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)]) {
                CallV(bubble, @selector(tony_onClickHongbaoMessage));
                L(@"SendGrab via tony_onClick hid=%@", hid);
            } else if ([bubble respondsToSelector:@selector(onClickHongbaoMessage)]) {
                CallV(bubble, @selector(onClickHongbaoMessage));
                L(@"SendGrab via onClick hid=%@", hid);
            } else {
                Cancel(hid);
                return;
            }
            // retain bubble until open window
            objc_setAssociatedObject(wwkMessage, "wwrg_bubble", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(wwkMessage, "wwrg_bubble", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
        } @catch (NSException *ex) {
            L(@"FireGrab ex %@", ex);
            Cancel(hid);
        }
    };

    NSInteger d = DelayMs();
    if (d <= 0) {
        if ([NSThread isMainThread]) go();
        else dispatch_async(dispatch_get_main_queue(), go);
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_MSEC)), dispatch_get_main_queue(), go);
    }
}

static id WrapMsg(void *modelPtr) {
    if (!modelPtr) return nil;
    Class c = NSClassFromString(@"WWKMessage");
    if (!c) return nil;
    @try {
        void *tmp = modelPtr;
        id o = [c alloc];
        if ([c instancesRespondToSelector:@selector(initWithMessage:observe:)])
            return ((id (*)(id, SEL, void *, BOOL))objc_msgSend)(o, @selector(initWithMessage:observe:), &tmp, NO);
        if ([c instancesRespondToSelector:@selector(initWithMessage:)])
            return ((id (*)(id, SEL, void *))objc_msgSend)(o, @selector(initWithMessage:), &tmp);
    } @catch (__unused NSException *e) {}
    return nil;
}

typedef struct { void **begin; void **end; void **cap; } Vec;

static void OnVec(const void *vec, NSString *conv) {
    if (!vec) return;
    const Vec *v = (const Vec *)vec;
    if (v->begin && v->end && v->end > v->begin) {
        ptrdiff_t n = v->end - v->begin;
        if (n > 0 && n <= 80) {
            for (ptrdiff_t i = 0; i < n; i++) {
                void *p = v->begin[i];
                if (!p) continue;
                id msg = WrapMsg(p);
                if (!msg) continue;
                CallV(msg, @selector(parseMessage));
                FireGrab(msg, conv);
            }
            return;
        }
    }
    void *one = *(void * const *)vec;
    if (one) {
        id msg = WrapMsg(one);
        if (msg) { CallV(msg, @selector(parseMessage)); FireGrab(msg, conv); }
    }
}

static NSString *ConvName(id w) {
    id n = Call(w, @selector(getName));
    return [n isKindOfClass:NSString.class] ? n : @"";
}

#pragma mark - Minimal settings ball (not red-packet UI)

@interface WWRGPanel : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UISwitch *en;
@property (nonatomic, strong) UISlider *delay;
@property (nonatomic, strong) UILabel *delayLab;
@property (nonatomic, strong) UILabel *stats;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSMutableArray *wl;
@end

@implementation WWRGPanel
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    self.wl = [WL() mutableCopy] ?: [NSMutableArray array];
    CGFloat W = self.view.bounds.size.width, y = 50;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, W - 90, 28)];
    t.text = @"秒抢 · 纯协议"; t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:17]; t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];

    UIButton *c = [UIButton buttonWithType:UIButtonTypeSystem];
    c.frame = CGRectMake(W - 70, 12, 54, 32); c.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [c setTitle:@"关闭" forState:UIControlStateNormal]; [c setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [c addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:c];

    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 120, 28)];
    el.text = @"自动抢"; el.textColor = UIColor.whiteColor; el.font = [UIFont systemFontOfSize:16];
    [self.view addSubview:el];
    self.en = [[UISwitch alloc] initWithFrame:CGRectMake(W - 70, y, 51, 31)];
    self.en.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin; self.en.on = On();
    [self.en addTarget:self action:@selector(onEn:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.en]; y += 42;

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W - 32, 36)];
    tip.text = @"无红包弹窗 · Grab→截ticket→UnWrap";
    tip.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.45 alpha:1];
    tip.font = [UIFont systemFontOfSize:12]; tip.numberOfLines = 2;
    tip.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:tip]; y += 40;

    UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 160, 24)];
    dl.text = @"延迟(0最快)"; dl.textColor = UIColor.whiteColor;
    [self.view addSubview:dl];
    self.delayLab = [[UILabel alloc] initWithFrame:CGRectMake(W - 90, y, 74, 24)];
    self.delayLab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    self.delayLab.textColor = UIColor.lightGrayColor;
    self.delayLab.textAlignment = NSTextAlignmentRight;
    [self.view addSubview:self.delayLab]; y += 26;
    self.delay = [[UISlider alloc] initWithFrame:CGRectMake(16, y, W - 32, 30)];
    self.delay.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.delay.minimumValue = 0; self.delay.maximumValue = 1000; self.delay.value = (float)DelayMs();
    [self.delay addTarget:self action:@selector(onD:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.delay];
    self.delayLab.text = [NSString stringWithFormat:@"%ldms", (long)self.delay.value]; y += 38;

    self.stats = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W - 32, 40)];
    self.stats.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    self.stats.font = [UIFont boldSystemFontOfSize:15]; self.stats.numberOfLines = 2;
    self.stats.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.stats];
    self.stats.text = [NSString stringWithFormat:@"累计 ¥%@  成功 %ld", Yuan(TotalFen()), (long)GrabCnt()]; y += 48;

    UIButton *rst = [UIButton buttonWithType:UIButtonTypeSystem];
    rst.frame = CGRectMake(16, y, 90, 30);
    [rst setTitle:@"清空统计" forState:UIControlStateNormal];
    [rst setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.35 alpha:1] forState:UIControlStateNormal];
    [rst addTarget:self action:@selector(onRst) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:rst]; y += 40;

    UILabel *wl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 200, 22)];
    wl.text = @"白名单(不抢)"; wl.textColor = UIColor.whiteColor;
    [self.view addSubview:wl]; y += 28;

    self.field = [[UITextField alloc] initWithFrame:CGRectMake(16, y, W - 100, 36)];
    self.field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.field.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    self.field.textColor = UIColor.whiteColor;
    self.field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"会话名包含" attributes:@{NSForegroundColorAttributeName: UIColor.grayColor}];
    self.field.layer.cornerRadius = 8;
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 36)];
    self.field.leftViewMode = UITextFieldViewModeAlways;
    self.field.delegate = self;
    [self.view addSubview:self.field];
    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(W - 76, y, 60, 36); add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"添加" forState:UIControlStateNormal]; [add setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    add.backgroundColor = [UIColor colorWithRed:0.15 green:0.6 blue:0.25 alpha:1]; add.layer.cornerRadius = 8;
    [add addTarget:self action:@selector(onAdd) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add]; y += 48;

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, y, W, MAX(100, self.view.bounds.size.height - y - 12)) style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.delegate = self; self.table.dataSource = self;
    [self.view addSubview:self.table];
}
- (void)onEn:(UISwitch *)s { [D() setBool:s.on forKey:kEn]; [D() synchronize]; RefreshBall(); }
- (void)onD:(UISlider *)s {
    [D() setInteger:(NSInteger)s.value forKey:kDly]; [D() synchronize];
    self.delayLab.text = [NSString stringWithFormat:@"%ldms", (long)s.value];
}
- (void)onRst {
    [D() setInteger:0 forKey:kFen]; [D() setInteger:0 forKey:kCnt]; [D() setObject:@[] forKey:kHis]; [D() synchronize];
    @synchronized (gLock) { [gAmtDone removeAllObjects]; }
    self.stats.text = @"累计 ¥0.00  成功 0"; RefreshBall();
}
- (void)onAdd {
    NSString *t = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
    if (![self.wl containsObject:t]) { [self.wl addObject:t]; SetWL(self.wl); [self.table reloadData]; }
    self.field.text = @""; [self.field resignFirstResponder];
}
- (void)close { gPanel.hidden = YES; gPanel = nil; }
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self onAdd]; return YES; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.wl.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    c.backgroundColor = UIColor.clearColor; c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.text = self.wl[ip.row]; c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return YES; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    [self.wl removeObjectAtIndex:ip.row]; SetWL(self.wl);
    [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}
- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip { return @"删除"; }
@end

static void ShowPanel(void) {
    if (gPanel) { gPanel.hidden = NO; return; }
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat w = MIN(sb.size.width - 24, 360), h = MIN(sb.size.height * 0.7, 560);
    gPanel = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width - w) / 2, (sb.size.height - h) / 2, w, h)];
    gPanel.windowLevel = UIWindowLevelAlert + 10;
    gPanel.layer.cornerRadius = 12; gPanel.clipsToBounds = YES;
    gPanel.rootViewController = [WWRGPanel new];
    gPanel.hidden = NO;
}

static void RefreshBall(void) {
    if (!gBall) return;
    BOOL on = On();
    [gBall setTitle:(on ? [NSString stringWithFormat:@"¥%@", Yuan(TotalFen())] : @"关") forState:UIControlStateNormal];
    gBall.backgroundColor = on ? [UIColor colorWithRed:0.12 green:0.62 blue:0.28 alpha:0.94]
                               : [UIColor colorWithWhite:0.35 alpha:0.9];
}

static void Drag(UIPanGestureRecognizer *pan) {
    UIView *v = pan.view;
    CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
    if (pan.state == UIGestureRecognizerStateEnded) {
        CGRect b = UIScreen.mainScreen.bounds;
        CGFloat x = v.center.x < b.size.width / 2 ? 28 : b.size.width - 28;
        CGFloat y = MIN(MAX(v.center.y, 70), b.size.height - 70);
        [UIView animateWithDuration:0.15 animations:^{ v.center = CGPointMake(x, y); }];
        [D() setDouble:x forKey:kBX]; [D() setDouble:y forKey:kBY]; [D() synchronize];
    }
}

static void EnsureUI(void) {
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
        CGFloat x = [D() doubleForKey:kBX], y = [D() doubleForKey:kBY];
        if (x < 10 || y < 10) { x = key.bounds.size.width - 28; y = key.bounds.size.height * 0.55; }
        gBall = [UIButton buttonWithType:UIButtonTypeCustom];
        gBall.frame = CGRectMake(0, 0, 54, 54); gBall.center = CGPointMake(x, y);
        gBall.layer.cornerRadius = 27; gBall.clipsToBounds = YES;
        gBall.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        gBall.titleLabel.adjustsFontSizeToFitWidth = YES; gBall.titleLabel.numberOfLines = 2;
        gBall.titleLabel.textAlignment = NSTextAlignmentCenter;
        [gBall setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        gBall.layer.borderWidth = 1; gBall.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;

        Class cls = NSClassFromString(@"WWRGBallProxy");
        if (!cls) {
            cls = objc_allocateClassPair(NSObject.class, "WWRGBallProxy", 0);
            class_addMethod(cls, NSSelectorFromString(@"pan:"),
                            imp_implementationWithBlock(^(id s, UIPanGestureRecognizer *p) { Drag(p); }), "v@:@");
            class_addMethod(cls, NSSelectorFromString(@"tap"),
                            imp_implementationWithBlock(^(id s) {
                if (gPanel && !gPanel.hidden) { gPanel.hidden = YES; gPanel = nil; }
                else ShowPanel();
            }), "v@:");
            objc_registerClassPair(cls);
        }
        static id px; if (!px) px = [cls new];
        [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:px action:NSSelectorFromString(@"pan:")]];
        [gBall addTarget:px action:NSSelectorFromString(@"tap") forControlEvents:UIControlEventTouchUpInside];
        [key addSubview:gBall]; RefreshBall(); gUIReady = YES;
        L(@"悬浮球就绪(仅设置,无红包UI)");
    });
}

#pragma mark - Install hooks

static void Install(void) {
    gLock = [NSObject new];
    gDone = [NSMutableSet set];
    gPending = [NSMutableSet set];
    gAmtDone = [NSMutableSet set];

    // 1) earliest message
    Class wrap = NSClassFromString(@"WWKConversationWrapper");
    if (wrap) {
        SEL o = @selector(OnAddMessage:end:inConversation:);
        SEL n = NSSelectorFromString(@"wwrg_add:end:cv:");
        Hook(wrap, o, n, ^(id self, const void *vec, BOOL end, void *cv) {
            ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, n, vec, end, cv);
            if (On()) OnVec(vec, ConvName(self));
        });
    }
    Class list = NSClassFromString(@"WWKMessageListController");
    if (list) {
        SEL o = @selector(OnAddMessage:end:inConversation:);
        SEL n = NSSelectorFromString(@"wwrg_ladd:end:cv:");
        Hook(list, o, n, ^(id self, const void *vec, BOOL end, void *cv) {
            ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, n, vec, end, cv);
            if (On()) OnVec(vec, @"");
        });
    }
    Class wmsg = NSClassFromString(@"WWKMessage");
    if (wmsg) {
        if (class_getInstanceMethod(wmsg, @selector(p_parseHongBaoMessage:))) {
            SEL n = NSSelectorFromString(@"wwrg_phb:");
            Hook(wmsg, @selector(p_parseHongBaoMessage:), n, ^(id self, const void *m) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, n, m);
                if (On()) FireGrab(self, gLastConv ?: @"");
            });
        }
        if (class_getInstanceMethod(wmsg, @selector(p_parseLishiHongBaoMessage:))) {
            SEL n = NSSelectorFromString(@"wwrg_plishi:");
            Hook(wmsg, @selector(p_parseLishiHongBaoMessage:), n, ^(id self, const void *m) {
                ((void (*)(id, SEL, const void *))objc_msgSend)(self, n, m);
                if (On()) FireGrab(self, gLastConv ?: @"");
            });
        }
    }

    // 2) KEY: openHongBaoWindow — steal ticket, silent unwrap, NO original UI
    Class mgr = NSClassFromString(@"WWRedEnvelopesMgr");
    if (mgr) {
        SEL o1 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:);
        if (class_getInstanceMethod(mgr, o1)) {
            SEL n = NSSelectorFromString(@"wwrg_ow1:v:tk:vt:c:m:");
            Method om = class_getInstanceMethod(mgr, o1);
            IMP imp = imp_implementationWithBlock(^(id self, const void *data, id vids, const void *tk, int vt, void *cv, void *msg) {
                if (On()) {
                    NSString *ticket = TicketFromPtr(tk);
                    L(@"截获 openHB1 ticket=%@ vt=%d — 静默UnWrap 不弹窗", ticket, vt);
                    if (ticket.length) gLastTicket = ticket;
                    SilentUnWrap(data, vids, tk, cv);
                    return; // skip UI
                }
                ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *))objc_msgSend)(
                    self, n, data, vids, tk, vt, cv, msg);
            });
            class_addMethod(mgr, n, imp, method_getTypeEncoding(om));
            Swizzle(mgr, o1, n);
        }

        SEL o2 = @selector(openHongBaoWindow:toVidList:hbTicket:vidTicket:conv:msg:openBlock:cancelBlock:);
        if (class_getInstanceMethod(mgr, o2)) {
            SEL n = NSSelectorFromString(@"wwrg_ow2:v:tk:vt:c:m:ob:cb:");
            Method om = class_getInstanceMethod(mgr, o2);
            IMP imp = imp_implementationWithBlock(^(id self, const void *data, id vids, const void *tk, int vt, void *cv, void *msg, id ob, id cb) {
                if (On()) {
                    NSString *ticket = TicketFromPtr(tk);
                    L(@"截获 openHB2 ticket=%@ ob=%@ — 静默UnWrap", ticket, ob);
                    if (ticket.length) gLastTicket = ticket;
                    // openBlock often NULL; still SilentUnWrap
                    if (ob) {
                        // try block first if present (protocol path)
                        @try {
                            void (^b)(void) = ob;
                            b();
                            L(@"openBlock 已调");
                        } @catch (__unused NSException *e) {
                            SilentUnWrap(data, vids, tk, cv);
                        }
                    } else {
                        SilentUnWrap(data, vids, tk, cv);
                    }
                    return;
                }
                ((void (*)(id, SEL, const void *, id, const void *, int, void *, void *, id, id))objc_msgSend)(
                    self, n, data, vids, tk, vt, cv, msg, ob, cb);
            });
            class_addMethod(mgr, n, imp, method_getTypeEncoding(om));
            Swizzle(mgr, o2, n);
        }

        if (class_getInstanceMethod(mgr, @selector(didOpenRedEvnSuc:))) {
            SEL n = NSSelectorFromString(@"wwrg_ok:");
            Hook(mgr, @selector(didOpenRedEvnSuc:), n, ^(id self, id arg) {
                ((void (*)(id, SEL, id))objc_msgSend)(self, n, arg);
                L(@"didOpenRedEvnSuc %@", arg);
                // amount usually already booked via setMSelfRecvAmount
                CallV(self, @selector(closeHongBaoWindow));
                CallV(self, @selector(closeResultWindow));
            });
        }
    }

    // 3) if any window still appears, nuke + force open
    Class win = NSClassFromString(@"WWRedEnvOpenHongBaoWindow");
    if (win) {
        if (class_getInstanceMethod(win, @selector(didMoveToWindow))) {
            SEL n = NSSelectorFromString(@"wwrg_mv");
            Hook(win, @selector(didMoveToWindow), n, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, n);
                if (!On()) return;
                if ([self isKindOfClass:UIView.class]) NukeView((UIView *)self);
                NSNumber *sil = objc_getAssociatedObject(self, "wwrg_silent");
                if (sil.boolValue) return; // our silent win already clicking
                // foreign window — steal click
                if ([self respondsToSelector:@selector(onOpenBtnClick:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(onOpenBtnClick:), nil);
                id mgr = Call(NSClassFromString(@"WWRedEnvelopesMgr"), @selector(shareInstance));
                CallV(mgr, @selector(closeHongBaoWindow));
            });
        }
        if (class_getInstanceMethod(win, @selector(layoutSubviews))) {
            SEL n = NSSelectorFromString(@"wwrg_lay");
            Hook(win, @selector(layoutSubviews), n, ^(id self) {
                ((void (*)(id, SEL))objc_msgSend)(self, n);
                if (On() && [self isKindOfClass:UIView.class]) NukeView((UIView *)self);
            });
        }
    }

    // 4) amount
    Class detail = NSClassFromString(@"WWRedEnvDetailViewController");
    if (detail && class_getInstanceMethod(detail, @selector(setMSelfRecvAmount:))) {
        SEL n = NSSelectorFromString(@"wwrg_amt:");
        Hook(detail, @selector(setMSelfRecvAmount:), n, ^(id self, unsigned long long fen) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(self, n, fen);
            if (!On()) return;
            L(@"金额 %llu 分", fen);
            NSString *hid = nil;
            id h = Call(self, @selector(mHongBaoID));
            if ([h isKindOfClass:NSString.class]) hid = h;
            Book(gLastConv, hid ?: gLastHid, (long long)fen, gLastWish);
            // dismiss detail
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    UIViewController *vc = (UIViewController *)self;
                    if ([vc isKindOfClass:UIViewController.class]) {
                        NukeView(vc.view);
                        if (vc.presentingViewController) [vc dismissViewControllerAnimated:NO completion:nil];
                        else if (vc.navigationController.topViewController == vc)
                            [vc.navigationController popViewControllerAnimated:NO];
                    }
                } @catch (__unused NSException *e) {}
            });
        });
    }
    if (detail && class_getInstanceMethod(detail, @selector(viewWillAppear:))) {
        SEL n = NSSelectorFromString(@"wwrg_dwa:");
        Hook(detail, @selector(viewWillAppear:), n, ^(id self, BOOL a) {
            if (On()) {
                UIView *v = [(UIViewController *)self view];
                v.hidden = YES; v.alpha = 0;
            }
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self, n, a);
        });
    }

    Class res = NSClassFromString(@"WWRedEnvOpenResultWindow");
    if (res && class_getInstanceMethod(res, @selector(_updateUIData:))) {
        SEL n = NSSelectorFromString(@"wwrg_rui:");
        Hook(res, @selector(_updateUIData:), n, ^(id self, BOOL f) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(self, n, f);
            if (!On()) return;
            if ([self isKindOfClass:UIView.class]) NukeView((UIView *)self);
            unsigned long long amt = CallQ(self, @selector(mTotalAmount));
            if (amt > 0) {
                NSString *hid = Call(self, @selector(mHongBaoID));
                Book(gLastConv, [hid isKindOfClass:NSString.class] ? hid : gLastHid, (long long)amt, gLastWish);
            }
            CallV(self, @selector(_closeRedEnvWindow));
        });
    }

    // in-chat bubble backup (if already viewing chat when HB arrives rendered)
    Class bubble = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
    if (bubble && class_getInstanceMethod(bubble, @selector(updateData))) {
        SEL n = NSSelectorFromString(@"wwrg_bupd");
        Hook(bubble, @selector(updateData), n, ^(id self) {
            ((void (*)(id, SEL))objc_msgSend)(self, n);
            if (!On()) return;
            id msg = Call(self, @selector(message));
            if (msg) FireGrab(msg, @"");
        });
    }

    L(@"安装完成 纯协议静默抢 enabled=%d delay=%ld", On(), (long)DelayMs());
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        L(@"load %@", NSBundle.mainBundle.bundleIdentifier);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Install();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EnsureUI();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gUIReady) EnsureUI();
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *n) {
            if (!gUIReady) EnsureUI();
            else if (gBall && !gBall.superview) { gUIReady = NO; EnsureUI(); }
        }];
    }
}
