#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * WWRedGrab v5
 *
 * Manual open crash was from block-swizzling openHongBaoWindow (C++ ABI).
 * v5: NEVER touch openHongBaoWindow / window UI methods.
 *
 * Detection:
 *  1) -[WWKMessage p_parseHongBaoMessage:]  (best: self is ready WWKMessage)
 *  2) -[WWKMessage p_parseLishiHongBaoMessage:]
 *  3) OnAddMessage end==YES as backup (C IMP, not block)
 *
 * Auto grab:
 *  delay -> fake bubble tony_onClick (Grab)
 *  poll currentActiveHongbaoWindow -> onOpenBtnClick (UnWrap)
 */

static NSString * const kEn  = @"wwrg_enabled";
static NSString * const kDly = @"wwrg_delay_ms";
static NSString * const kWL  = @"wwrg_whitelist";
static NSString * const kFen = @"wwrg_total_fen";
static NSString * const kCnt = @"wwrg_grab_count";
static NSString * const kHis = @"wwrg_history";
static NSString * const kBX  = @"wwrg_ball_x";
static NSString * const kBY  = @"wwrg_ball_y";

static UIButton *gBall;
static UIWindow *gPanel;
static BOOL gUIReady;
static NSObject *gLock;
static NSMutableSet *gDone;
static NSMutableSet *gPending;
static NSMutableSet *gAmtDone;
static NSString *gLastHid;
static NSString *gLastConv;
static NSString *gLastWish;
static NSString *gArmedHid;
static NSInteger gArmGen;
static BOOL gClicking;

static void L(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void L(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSLog(@"[WWRedGrab] %@", [[NSString alloc] initWithFormat:fmt arguments:ap]);
    va_end(ap);
}

static NSUserDefaults *UD(void) { return NSUserDefaults.standardUserDefaults; }
static BOOL On(void) {
    if (![UD() objectForKey:kEn]) return YES;
    return [UD() boolForKey:kEn];
}
static NSInteger DelayMs(void) {
    NSInteger v = [UD() integerForKey:kDly];
    if (v < 150) v = 150;
    if (v > 3000) v = 3000;
    return v;
}
static NSArray *WL(void) { return [UD() arrayForKey:kWL] ?: @[]; }
static void SetWL(NSArray *a) { [UD() setObject:a ?: @[] forKey:kWL]; [UD() synchronize]; }
static long long TotalFen(void) { return (long long)[UD() integerForKey:kFen]; }
static NSInteger GrabCnt(void) { return [UD() integerForKey:kCnt]; }
static NSString *Yuan(long long f) { return [NSString stringWithFormat:@"%.2f", f / 100.0]; }

static BOOL IsWL(NSString *name) {
    if (!name.length) return NO;
    NSString *n = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *w in WL()) {
        NSString *t = [w stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length && ([n containsString:t] || [t containsString:n])) return YES;
    }
    return NO;
}
static BOOL Begin(NSString *hid) {
    if (!hid.length) return NO;
    @synchronized (gLock) {
        if ([gDone containsObject:hid] || [gPending containsObject:hid]) return NO;
        [gPending addObject:hid];
        return YES;
    }
}
static void End(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) { [gPending removeObject:hid]; [gDone addObject:hid]; }
}
static void Cancel(NSString *hid) {
    if (!hid.length) return;
    @synchronized (gLock) { [gPending removeObject:hid]; }
}
static void ClearArmIf(NSString *hid) {
    @synchronized (gLock) {
        if (hid.length && [gArmedHid isEqualToString:hid]) gArmedHid = nil;
    }
}
static void Arm(NSString *hid) {
    @synchronized (gLock) { gArmedHid = [hid copy]; gArmGen++; }
    NSInteger gen = gArmGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @synchronized (gLock) { if (gArmGen == gen) gArmedHid = nil; }
    });
}

static id Call(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static void CallV(id o, SEL s) {
    if (!o || !s || ![o respondsToSelector:s]) return;
    ((void (*)(id, SEL))objc_msgSend)(o, s);
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
    NSMutableArray *arr = [[UD() arrayForKey:kHis] mutableCopy] ?: [NSMutableArray array];
    [arr insertObject:@{
        @"t": @(NSDate.date.timeIntervalSince1970),
        @"conv": conv ?: @"", @"hid": hid ?: @"",
        @"fen": @(fen), @"wish": wish ?: @""
    } atIndex:0];
    while (arr.count > 100) [arr removeLastObject];
    [UD() setObject:arr forKey:kHis];
    if (fen > 0) [UD() setInteger:(NSInteger)(TotalFen() + fen) forKey:kFen];
    [UD() setInteger:GrabCnt() + 1 forKey:kCnt];
    [UD() synchronize];
    L(@"book Y%@ fen=%lld hid=%@", Yuan(fen), fen, hid);
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshBall(); });
}

/* C IMP swap — safe for pointer/BOOL args. Do NOT use for C++ by-value types. */
static void Exchange(Class c, SEL sel, IMP neu, IMP *outOrig) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { L(@"no method %@ %s", c, sel_getName(sel)); return; }
    IMP old = method_getImplementation(m);
    if (outOrig) *outOrig = old;
    method_setImplementation(m, neu);
    L(@"exchange %@ %s", c, sel_getName(sel));
}

static id Mgr(void) {
    return Call(NSClassFromString(@"WWRedEnvelopesMgr"), @selector(shareInstance));
}
static id ActiveWin(void) {
    id mgr = Mgr();
    id win = Call(mgr, @selector(currentActiveHongbaoWindow));
    if (win) return win;
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(mgr), "_mHongBaoWindow");
        if (iv) return object_getIvar(mgr, iv);
    } @catch (__unused NSException *e) {}
    return nil;
}

static void PollAndOpen(NSString *hid) {
    if (!On() || !hid.length) return;
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.2 + 0.15 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gClicking) return;
            NSString *armed = nil;
            @synchronized (gLock) { armed = [gArmedHid copy]; }
            if (![armed isEqualToString:hid]) return;
            id win = ActiveWin();
            if (!win) {
                if (i == 5 || i == 10 || i == 15) L(@"poll no win yet hid=%@ i=%d", hid, i);
                return;
            }
            gClicking = YES;
            L(@"AUTO open click hid=%@ win=%@", hid, win);
            if ([win isKindOfClass:UIView.class]) {
                UIView *v = (UIView *)win;
                v.alpha = 0.01;
                v.userInteractionEnabled = NO;
            }
            @try {
                if ([win respondsToSelector:@selector(onOpenBtnClick:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(onOpenBtnClick:), nil);
            } @catch (NSException *ex) {
                L(@"onOpenBtnClick ex %@", ex);
            }
            ClearArmIf(hid);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                id mgr = Mgr();
                CallV(mgr, @selector(closeHongBaoWindow));
                CallV(mgr, @selector(closeResultWindow));
                gClicking = NO;
            });
        });
    }
}

static BOOL IsHB(id item) {
    if (!item) return NO;
    NSString *cn = NSStringFromClass([item class]);
    return [cn containsString:@"MessageRedEnvelopes"] ||
           [cn containsString:@"LishiRedEnvelopes"] ||
           [item respondsToSelector:@selector(hongbaoID)];
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

static void FireGrab(id msg, NSString *conv) {
    if (!On() || !msg) return;
    if (IsWL(conv)) { L(@"whitelist skip %@", conv); return; }

    // ensure parsed
    @try { if ([msg respondsToSelector:@selector(parseMessage)]) CallV(msg, @selector(parseMessage)); } @catch (__unused NSException *e) {}

    id item = Call(msg, @selector(messageItem));
    if (!IsHB(item)) {
        NSArray *items = Call(msg, @selector(messageItems));
        if ([items isKindOfClass:NSArray.class])
            for (id it in items) if (IsHB(it)) { item = it; break; }
    }
    if (!IsHB(item)) {
        L(@"no HB item on msg %@", msg);
        return;
    }

    NSString *hid = HidOf(item);
    if (!hid.length) { L(@"empty hid"); return; }
    if (!Begin(hid)) return;

    gLastHid = [hid copy];
    gLastConv = [conv ?: @"" copy];
    gLastWish = [WishOf(item) ?: @"" copy];
    Arm(hid);
    L(@"FOUND hid=%@ wish=%@ conv=%@", hid, gLastWish, conv);

    NSInteger dly = DelayMs();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dly * NSEC_PER_SEC / 1000)), dispatch_get_main_queue(), ^{
        @try {
            Class bcls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
            if (!bcls) { Cancel(hid); ClearArmIf(hid); L(@"no bubble class"); return; }
            id bubble = [[bcls alloc] init];
            if ([bubble respondsToSelector:@selector(setMessage:)])
                ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), msg);
            else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)])
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), msg, 0);

            // updateData helps fill internal state for click path
            if ([bubble respondsToSelector:@selector(updateData)])
                CallV(bubble, @selector(updateData));

            if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)]) {
                CallV(bubble, @selector(tony_onClickHongbaoMessage));
                L(@"Grab via tony hid=%@", hid);
            } else if ([bubble respondsToSelector:@selector(onClickHongbaoMessage)]) {
                CallV(bubble, @selector(onClickHongbaoMessage));
                L(@"Grab via onClick hid=%@", hid);
            } else {
                Cancel(hid); ClearArmIf(hid); return;
            }

            objc_setAssociatedObject(msg, "wwrg_b", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(msg, "wwrg_b", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            PollAndOpen(hid);
        } @catch (NSException *ex) {
            L(@"FireGrab ex %@", ex);
            Cancel(hid); ClearArmIf(hid);
        }
    });
}

/* -------- C hooks (not blocks) -------- */

// p_parseHongBaoMessage:  encoding v24@0:8r^v16
static void (*orig_parseHB)(id, SEL, const void *);
static void hook_parseHB(id self, SEL sel, const void *m) {
    if (orig_parseHB) orig_parseHB(self, sel, m);
    else ((void (*)(id, SEL, const void *))objc_msgSend)(self, sel, m);
    if (!On()) return;
    // self is WWKMessage after parse
    L(@"p_parseHongBaoMessage self=%@", self);
    FireGrab(self, gLastConv ?: @"");
}

static void (*orig_parseLishi)(id, SEL, const void *);
static void hook_parseLishi(id self, SEL sel, const void *m) {
    if (orig_parseLishi) orig_parseLishi(self, sel, m);
    else ((void (*)(id, SEL, const void *))objc_msgSend)(self, sel, m);
    if (!On()) return;
    L(@"p_parseLishiHongBaoMessage self=%@", self);
    FireGrab(self, gLastConv ?: @"");
}

// OnAddMessage:end:inConversation:
// encoding v36@0:8r^v16B24{scoped_refptr}28 — last is 8-byte, pass as void* slot
static void (*orig_addMsg)(id, SEL, const void *, BOOL, void *);
static void hook_addMsg(id self, SEL sel, const void *vec, BOOL end, void *conv) {
    if (orig_addMsg) orig_addMsg(self, sel, vec, end, conv);
    if (!On() || !end || !vec) return;

    // Try wrap messages while vec still valid
    typedef struct { void **begin; void **end; void **cap; } Vec;
    NSMutableArray *msgs = [NSMutableArray array];
    @try {
        const Vec *v = (const Vec *)vec;
        if (v->begin && v->end && v->end > v->begin) {
            ptrdiff_t n = v->end - v->begin;
            if (n > 0 && n <= 20) {
                for (ptrdiff_t i = 0; i < n; i++) {
                    void *p = v->begin[i];
                    if (!p) continue;
                    Class mc = NSClassFromString(@"WWKMessage");
                    if (!mc) continue;
                    void *tmp = p;
                    id o = [mc alloc];
                    id msg = nil;
                    if ([mc instancesRespondToSelector:@selector(initWithMessage:observe:)])
                        msg = ((id (*)(id, SEL, void *, BOOL))objc_msgSend)(o, @selector(initWithMessage:observe:), &tmp, NO);
                    else if ([mc instancesRespondToSelector:@selector(initWithMessage:)])
                        msg = ((id (*)(id, SEL, void *))objc_msgSend)(o, @selector(initWithMessage:), &tmp);
                    if (msg) [msgs addObject:msg];
                }
            }
        }
    } @catch (NSException *ex) {
        L(@"addMsg wrap ex %@", ex);
    }

    NSString *convName = @"";
    @try {
        id n = Call(self, @selector(getName));
        if ([n isKindOfClass:NSString.class]) convName = n;
    } @catch (__unused NSException *e) {}

    if (msgs.count) {
        L(@"OnAddMessage end msgs=%lu conv=%@", (unsigned long)msgs.count, convName);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (id msg in msgs) FireGrab(msg, convName);
        });
    }
}

// amount
static void (*orig_setAmt)(id, SEL, unsigned long long);
static void hook_setAmt(id self, SEL sel, unsigned long long fen) {
    if (orig_setAmt) orig_setAmt(self, sel, fen);
    else ((void (*)(id, SEL, unsigned long long))objc_msgSend)(self, sel, fen);
    if (!On() || fen == 0) return;
    id h = Call(self, @selector(mHongBaoID));
    NSString *hid = [h isKindOfClass:NSString.class] ? h : gLastHid;
    BOOL ours = NO;
    @synchronized (gLock) {
        ours = (hid.length && ([gPending containsObject:hid] || [gDone containsObject:hid] || [hid isEqualToString:gLastHid]));
    }
    if (!ours) return;
    L(@"amount %llu fen hid=%@", fen, hid);
    Book(gLastConv, hid, (long long)fen, gLastWish);
}

#pragma mark - UI

@interface WWRGPanel : UIViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UISwitch *en;
@property (nonatomic, strong) UISlider *delay;
@property (nonatomic, strong) UILabel *dLab;
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
    t.text = @"HB Grab v5"; t.textColor = UIColor.whiteColor;
    t.font = [UIFont boldSystemFontOfSize:17];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:t];
    UIButton *c = [UIButton buttonWithType:UIButtonTypeSystem];
    c.frame = CGRectMake(W - 70, 12, 54, 32);
    c.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [c setTitle:@"Close" forState:UIControlStateNormal];
    [c setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [c addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:c];
    UILabel *el = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 120, 28)];
    el.text = @"Auto"; el.textColor = UIColor.whiteColor; [self.view addSubview:el];
    self.en = [[UISwitch alloc] initWithFrame:CGRectMake(W - 70, y, 51, 31)];
    self.en.on = On();
    self.en.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.en addTarget:self action:@selector(onEn:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.en]; y += 44;
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W - 32, 55)];
    tip.numberOfLines = 4; tip.font = [UIFont systemFontOfSize:12];
    tip.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.5 alpha:1];
    tip.text = @"v5: no openHB hook (manual safe)\ndetect: parseHongBao + OnAddMessage\nauto: tony_onClick + poll open";
    [self.view addSubview:tip]; y += 60;
    UILabel *dl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 200, 24)];
    dl.text = @"delay ms"; dl.textColor = UIColor.whiteColor; [self.view addSubview:dl];
    self.dLab = [[UILabel alloc] initWithFrame:CGRectMake(W - 90, y, 74, 24)];
    self.dLab.textAlignment = NSTextAlignmentRight;
    self.dLab.textColor = UIColor.lightGrayColor;
    self.dLab.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [self.view addSubview:self.dLab]; y += 26;
    self.delay = [[UISlider alloc] initWithFrame:CGRectMake(16, y, W - 32, 30)];
    self.delay.minimumValue = 150; self.delay.maximumValue = 2000;
    NSInteger dv = [UD() integerForKey:kDly]; if (dv < 150) dv = 250;
    self.delay.value = (float)dv;
    [self.delay addTarget:self action:@selector(onD:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.delay];
    self.dLab.text = [NSString stringWithFormat:@"%ld", (long)self.delay.value]; y += 40;
    self.stats = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W - 32, 40)];
    self.stats.textColor = [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
    self.stats.font = [UIFont boldSystemFontOfSize:15]; self.stats.numberOfLines = 2;
    self.stats.text = [NSString stringWithFormat:@"total Y%@ count %ld", Yuan(TotalFen()), (long)GrabCnt()];
    [self.view addSubview:self.stats]; y += 48;
    UIButton *rst = [UIButton buttonWithType:UIButtonTypeSystem];
    rst.frame = CGRectMake(16, y, 80, 30);
    [rst setTitle:@"reset" forState:UIControlStateNormal];
    [rst setTitleColor:[UIColor colorWithRed:1 green:0.4 blue:0.35 alpha:1] forState:UIControlStateNormal];
    [rst addTarget:self action:@selector(onRst) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:rst]; y += 40;
    UILabel *wl = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 200, 22)];
    wl.text = @"whitelist skip"; wl.textColor = UIColor.whiteColor; [self.view addSubview:wl]; y += 28;
    self.field = [[UITextField alloc] initWithFrame:CGRectMake(16, y, W - 100, 36)];
    self.field.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    self.field.textColor = UIColor.whiteColor; self.field.layer.cornerRadius = 8;
    self.field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 36)];
    self.field.leftViewMode = UITextFieldViewModeAlways; self.field.delegate = self;
    self.field.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.field];
    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(W - 76, y, 60, 36);
    add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"add" forState:UIControlStateNormal];
    [add setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    add.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.25 alpha:1];
    add.layer.cornerRadius = 8;
    [add addTarget:self action:@selector(onAdd) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:add]; y += 48;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, y, W, MAX(80, self.view.bounds.size.height - y - 10)) style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.delegate = self; self.table.dataSource = self;
    [self.view addSubview:self.table];
}
- (void)onEn:(UISwitch *)s { [UD() setBool:s.on forKey:kEn]; [UD() synchronize]; RefreshBall(); }
- (void)onD:(UISlider *)s {
    [UD() setInteger:(NSInteger)s.value forKey:kDly]; [UD() synchronize];
    self.dLab.text = [NSString stringWithFormat:@"%ld", (long)s.value];
}
- (void)onRst {
    [UD() setInteger:0 forKey:kFen]; [UD() setInteger:0 forKey:kCnt];
    [UD() setObject:@[] forKey:kHis]; [UD() synchronize];
    @synchronized (gLock) { [gAmtDone removeAllObjects]; }
    self.stats.text = @"total Y0.00 count 0"; RefreshBall();
}
- (void)onAdd {
    NSString *t = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!t.length) return;
    if (![self.wl containsObject:t]) { [self.wl addObject:t]; SetWL(self.wl); [self.table reloadData]; }
    self.field.text = @""; [self.field resignFirstResponder];
}
- (void)close { gPanel.hidden = YES; gPanel = nil; }
- (BOOL)textFieldShouldReturn:(UITextField *)t { [self onAdd]; return YES; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.wl.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    c.backgroundColor = UIColor.clearColor;
    c.textLabel.textColor = UIColor.whiteColor;
    c.textLabel.text = self.wl[ip.row];
    return c;
}
- (void)tableView:(UITableView *)t commitEditingStyle:(UITableViewCellEditingStyle)e forRowAtIndexPath:(NSIndexPath *)ip {
    if (e != UITableViewCellEditingStyleDelete) return;
    [self.wl removeObjectAtIndex:ip.row]; SetWL(self.wl);
    [t deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
}
@end

static void ShowPanel(void) {
    if (gPanel) { gPanel.hidden = NO; return; }
    CGRect sb = UIScreen.mainScreen.bounds;
    CGFloat w = MIN(sb.size.width - 24, 360), h = MIN(sb.size.height * 0.7, 580);
    gPanel = [[UIWindow alloc] initWithFrame:CGRectMake((sb.size.width - w) / 2, (sb.size.height - h) / 2, w, h)];
    gPanel.windowLevel = UIWindowLevelAlert + 10;
    gPanel.layer.cornerRadius = 12; gPanel.clipsToBounds = YES;
    gPanel.rootViewController = [WWRGPanel new];
    gPanel.hidden = NO;
}
static void RefreshBall(void) {
    if (!gBall) return;
    BOOL on = On();
    [gBall setTitle:(on ? [NSString stringWithFormat:@"Y%@", Yuan(TotalFen())] : @"OFF") forState:UIControlStateNormal];
    gBall.backgroundColor = on ? [UIColor colorWithRed:0.12 green:0.6 blue:0.28 alpha:0.94] : [UIColor colorWithWhite:0.35 alpha:0.9];
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
        [UD() setDouble:x forKey:kBX]; [UD() setDouble:y forKey:kBY]; [UD() synchronize];
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
        CGFloat x = [UD() doubleForKey:kBX], y = [UD() doubleForKey:kBY];
        if (x < 10 || y < 10) { x = key.bounds.size.width - 28; y = key.bounds.size.height * 0.55; }
        gBall = [UIButton buttonWithType:UIButtonTypeCustom];
        gBall.frame = CGRectMake(0, 0, 54, 54);
        gBall.center = CGPointMake(x, y);
        gBall.layer.cornerRadius = 27; gBall.clipsToBounds = YES;
        gBall.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        gBall.titleLabel.adjustsFontSizeToFitWidth = YES;
        gBall.titleLabel.numberOfLines = 2;
        gBall.titleLabel.textAlignment = NSTextAlignmentCenter;
        [gBall setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        Class cls = NSClassFromString(@"WWRGBallP5");
        if (!cls) {
            cls = objc_allocateClassPair(NSObject.class, "WWRGBallP5", 0);
            class_addMethod(cls, NSSelectorFromString(@"p:"), imp_implementationWithBlock(^(id s, UIPanGestureRecognizer *p){ Drag(p); }), "v@:@");
            class_addMethod(cls, NSSelectorFromString(@"t"), imp_implementationWithBlock(^(id s){
                if (gPanel && !gPanel.hidden) { gPanel.hidden = YES; gPanel = nil; }
                else ShowPanel();
            }), "v@:");
            objc_registerClassPair(cls);
        }
        static id px; if (!px) px = [cls new];
        [gBall addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:px action:NSSelectorFromString(@"p:")]];
        [gBall addTarget:px action:NSSelectorFromString(@"t") forControlEvents:UIControlEventTouchUpInside];
        [key addSubview:gBall];
        RefreshBall();
        gUIReady = YES;
        L(@"ball ready v5");
    });
}

static void Install(void) {
    gLock = [NSObject new];
    gDone = [NSMutableSet set];
    gPending = [NSMutableSet set];
    gAmtDone = [NSMutableSet set];

    Class wmsg = NSClassFromString(@"WWKMessage");
    if (wmsg) {
        Exchange(wmsg, @selector(p_parseHongBaoMessage:), (IMP)hook_parseHB, (IMP *)&orig_parseHB);
        Exchange(wmsg, @selector(p_parseLishiHongBaoMessage:), (IMP)hook_parseLishi, (IMP *)&orig_parseLishi);
    }

    Class wrap = NSClassFromString(@"WWKConversationWrapper");
    if (wrap) {
        Exchange(wrap, @selector(OnAddMessage:end:inConversation:), (IMP)hook_addMsg, (IMP *)&orig_addMsg);
    }

    Class detail = NSClassFromString(@"WWRedEnvDetailViewController");
    if (detail) {
        Exchange(detail, @selector(setMSelfRecvAmount:), (IMP)hook_setAmt, (IMP *)&orig_setAmt);
    }

    L(@"v5 installed. parseHB+OnAdd only. on=%d delay=%ld", On(), (long)DelayMs());
}

__attribute__((constructor))
static void Init(void) {
    @autoreleasepool {
        L(@"load %@", NSBundle.mainBundle.bundleIdentifier);
        if (![UD() objectForKey:kDly]) [UD() setInteger:250 forKey:kDly];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Install(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ EnsureUI(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!gUIReady) EnsureUI(); });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
            if (!gUIReady) EnsureUI();
            else if (gBall && !gBall.superview) { gUIReady = NO; EnsureUI(); }
        }];
    }
}
