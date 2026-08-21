#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* WWRedGrab v4
 * NEVER hook openHongBaoWindow (scoped_refptr ABI breaks manual open).
 * Only OnAddMessage(end==YES) + setMSelfRecvAmount (our hids only).
 * Auto: delay -> tony_onClick -> poll ActiveWin -> onOpenBtnClick.
 */

static NSString * const kEn = @"wwrg_enabled";
static NSString * const kDly = @"wwrg_delay_ms";
static NSString * const kWL = @"wwrg_whitelist";
static NSString * const kFen = @"wwrg_total_fen";
static NSString * const kCnt = @"wwrg_grab_count";
static NSString * const kHis = @"wwrg_history";
static NSString * const kBX = @"wwrg_ball_x";
static NSString * const kBY = @"wwrg_ball_y";

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        @"conv": conv ?: @"",
        @"hid": hid ?: @"",
        @"fen": @(fen),
        @"wish": wish ?: @""
    } atIndex:0];
    while (arr.count > 100) [arr removeLastObject];
    [UD() setObject:arr forKey:kHis];
    if (fen > 0) [UD() setInteger:(NSInteger)(TotalFen() + fen) forKey:kFen];
    [UD() setInteger:GrabCnt() + 1 forKey:kCnt];
    [UD() synchronize];
    L(@"book Y%@ fen=%lld hid=%@", Yuan(fen), fen, hid);
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshBall(); });
}
static void Swizzle(Class c, SEL o, SEL n) {
    if (!c) return;
    Method om = class_getInstanceMethod(c, o);
    Method nm = class_getInstanceMethod(c, n);
    if (!om || !nm) { L(@"miss %@ %s", c, sel_getName(o)); return; }
    if (class_addMethod(c, o, method_getImplementation(nm), method_getTypeEncoding(nm)))
        class_replaceMethod(c, n, method_getImplementation(om), method_getTypeEncoding(om));
    else method_exchangeImplementations(om, nm);
    L(@"hook %@ %s", c, sel_getName(o));
}
static void Hook(Class c, SEL o, SEL n, id block) {
    if (!c || !class_getInstanceMethod(c, o)) return;
    Method om = class_getInstanceMethod(c, o);
    class_addMethod(c, n, imp_implementationWithBlock(block), method_getTypeEncoding(om));
    Swizzle(c, o, n);
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
    for (int i = 0; i < 15; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.15 + 0.12 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gClicking) return;
            NSString *armed = nil;
            @synchronized (gLock) { armed = [gArmedHid copy]; }
            if (![armed isEqualToString:hid]) return;
            id win = ActiveWin();
            if (!win) return;
            gClicking = YES;
            L(@"poll win auto-open hid=%@", hid);
            if ([win isKindOfClass:UIView.class]) {
                ((UIView *)win).alpha = 0.01;
                ((UIView *)win).userInteractionEnabled = NO;
            }
            @try {
                if ([win respondsToSelector:@selector(onOpenBtnClick:)])
                    ((void (*)(id, SEL, id))objc_msgSend)(win, @selector(onOpenBtnClick:), nil);
            } @catch (NSException *ex) {
                L(@"open ex %@", ex);
            }
            ClearArmIf(hid);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
    if (IsWL(conv)) return;
    id item = Call(msg, @selector(messageItem));
    if (!IsHB(item)) {
        NSArray *items = Call(msg, @selector(messageItems));
        if ([items isKindOfClass:NSArray.class])
            for (id it in items) if (IsHB(it)) { item = it; break; }
    }
    if (!IsHB(item)) return;
    NSString *hid = HidOf(item);
    if (!hid.length) return;
    if (!Begin(hid)) return;
    gLastHid = [hid copy];
    gLastConv = [conv ?: @"" copy];
    gLastWish = [WishOf(item) ?: @"" copy];
    Arm(hid);
    L(@"found HB hid=%@ conv=%@", hid, conv);
    NSInteger dly = DelayMs();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dly * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        @try {
            Class bcls = NSClassFromString(@"WWKConversationRedEnvelopesBubbleView");
            if (!bcls) { Cancel(hid); ClearArmIf(hid); return; }
            id bubble = [[bcls alloc] init];
            if ([bubble respondsToSelector:@selector(setMessage:)])
                ((void (*)(id, SEL, id))objc_msgSend)(bubble, @selector(setMessage:), msg);
            else if ([bubble respondsToSelector:@selector(setMessage:withItemIndex:)])
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(bubble, @selector(setMessage:withItemIndex:), msg, 0);
            if ([bubble respondsToSelector:@selector(tony_onClickHongbaoMessage)]) {
                CallV(bubble, @selector(tony_onClickHongbaoMessage));
                L(@"tony_onClick hid=%@", hid);
            } else if ([bubble respondsToSelector:@selector(onClickHongbaoMessage)]) {
                CallV(bubble, @selector(onClickHongbaoMessage));
                L(@"onClick hid=%@", hid);
            } else {
                Cancel(hid); ClearArmIf(hid); return;
            }
            objc_setAssociatedObject(msg, "wwrg_b", bubble, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(msg, "wwrg_b", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            PollAndOpen(hid);
        } @catch (NSException *ex) {
            L(@"FireGrab ex %@", ex);
            Cancel(hid); ClearArmIf(hid);
        }
    });
}
static id WrapMsg(void *p) {
    if (!p) return nil;
    Class c = NSClassFromString(@"WWKMessage");
    if (!c) return nil;
    @try {
        void *tmp = p;
        id o = [c alloc];
        if ([c instancesRespondToSelector:@selector(initWithMessage:observe:)])
            return ((id (*)(id, SEL, void *, BOOL))objc_msgSend)(o, @selector(initWithMessage:observe:), &tmp, NO);
        if ([c instancesRespondToSelector:@selector(initWithMessage:)])
            return ((id (*)(id, SEL, void *))objc_msgSend)(o, @selector(initWithMessage:), &tmp);
    } @catch (__unused NSException *e) {}
    return nil;
}
typedef struct { void **begin; void **end; void **cap; } Vec;
static void HandleVecSync(const void *vec, NSString *conv) {
    if (!vec || !On()) return;
    NSMutableArray *msgs = [NSMutableArray array];
    @try {
        const Vec *v = (const Vec *)vec;
        if (v->begin && v->end && v->end > v->begin) {
            ptrdiff_t n = v->end - v->begin;
            if (n > 0 && n <= 15) {
                for (ptrdiff_t i = 0; i < n; i++) {
                    void *p = v->begin[i];
                    if (!p) continue;
                    id msg = WrapMsg(p);
                    if (msg) [msgs addObject:msg];
                }
            }
        } else {
            void *one = *(void * const *)vec;
            if (one) {
                id msg = WrapMsg(one);
                if (msg) [msgs addObject:msg];
            }
        }
    } @catch (NSException *ex) {
        L(@"wrap ex %@", ex);
        return;
    }
    if (!msgs.count) return;
    NSString *c = [conv copy] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        for (id msg in msgs) FireGrab(msg, c);
    });
}
static NSString *CName(id w) {
    id n = Call(w, @selector(getName));
    return [n isKindOfClass:NSString.class] ? n : @"";
}

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
    t.text = @"HB Grab v4"; t.textColor = UIColor.whiteColor;
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
    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(16, y, W - 32, 50)];
    tip.numberOfLines = 3; tip.font = [UIFont systemFontOfSize:12];
    tip.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.5 alpha:1];
    tip.text = @"v4: no openHB hook\nmanual open should work\nauto = recv Grab + poll open";
    [self.view addSubview:tip]; y += 56;
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
    CGFloat w = MIN(sb.size.width - 24, 360), h = MIN(sb.size.height * 0.68, 560);
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
        Class cls = NSClassFromString(@"WWRGBallP4");
        if (!cls) {
            cls = objc_allocateClassPair(NSObject.class, "WWRGBallP4", 0);
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
        L(@"ball ready v4");
    });
}

static void Install(void) {
    gLock = [NSObject new];
    gDone = [NSMutableSet set];
    gPending = [NSMutableSet set];
    gAmtDone = [NSMutableSet set];

    Class wrap = NSClassFromString(@"WWKConversationWrapper");
    if (wrap) {
        SEL o = @selector(OnAddMessage:end:inConversation:);
        SEL n = NSSelectorFromString(@"wwrg_add:e:c:");
        Hook(wrap, o, n, ^(id self, const void *vec, BOOL end, void *cv) {
            ((void (*)(id, SEL, const void *, BOOL, void *))objc_msgSend)(self, n, vec, end, cv);
            if (On() && end) HandleVecSync(vec, CName(self));
        });
    }

    Class detail = NSClassFromString(@"WWRedEnvDetailViewController");
    if (detail && class_getInstanceMethod(detail, @selector(setMSelfRecvAmount:))) {
        SEL n = NSSelectorFromString(@"wwrg_amt:");
        Hook(detail, @selector(setMSelfRecvAmount:), n, ^(id self, unsigned long long fen) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(self, n, fen);
            if (!On() || fen == 0) return;
            id h = Call(self, @selector(mHongBaoID));
            NSString *hid = [h isKindOfClass:NSString.class] ? h : gLastHid;
            BOOL ours = NO;
            @synchronized (gLock) {
                ours = (hid.length && ([gPending containsObject:hid] || [gDone containsObject:hid] || [gLastHid isEqualToString:hid]));
            }
            if (!ours) return;
            L(@"amount %llu fen hid=%@", fen, hid);
            Book(gLastConv, hid, (long long)fen, gLastWish);
        });
    }

    L(@"v4 installed NO openHB hooks. on=%d delay=%ld", On(), (long)DelayMs());
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
