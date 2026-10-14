// ChatSwipe + KbDock — 合并版（两个功能同装一个插件）
//   A. ChatSwipe 原功能：聊天输入框左滑清空 / 右滑粘贴 + 编辑菜单精简（只留 全选/复制/粘贴）
//   B. KbDock     新功能：键盘底部快捷条（全选 / 复制 / 粘贴），自绘单点图标，自适应深浅色
// 交付：单 dylib，经 TrollFools 注入目标进程。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

// =====================================================================
//  A. ChatSwipe —— 滑动 + 编辑菜单精简（原作者代码，原样保留）
// =====================================================================

// ---- 配置（可选 /var/mobile/Documents/chatswipe.plist） ----
static BOOL     gEnabled      = YES;   // 总开关
static BOOL     gClearEnabled = YES;   // 左滑清空
static BOOL     gPasteEnabled = YES;   // 右滑粘贴
static CGFloat  gThreshold    = 45.0;  // 触发所需最小水平位移(pt)
static BOOL     gMenuFilterEnabled = YES; // 编辑菜单精简总开关（只留 全选/复制/粘贴）

// ---- 编辑菜单三件套 ----
static BOOL chatmenu_isAllowedAction(SEL action) {
    if (action == @selector(selectAll:)) return YES;
    if (action == @selector(copy:))      return YES;
    if (action == @selector(paste:))     return YES;
    return NO;
}

static void chatswipe_loadConfig() {
    @try {
        NSString *path = @"/var/mobile/Documents/chatswipe.plist";
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if (cfg) {
            if ([cfg objectForKey:@"Enabled"])          gEnabled          = [[cfg objectForKey:@"Enabled"]          boolValue];
            if ([cfg objectForKey:@"ClearEnabled"])      gClearEnabled     = [[cfg objectForKey:@"ClearEnabled"]      boolValue];
            if ([cfg objectForKey:@"PasteEnabled"])      gPasteEnabled     = [[cfg objectForKey:@"PasteEnabled"]      boolValue];
            if ([cfg objectForKey:@"Threshold"])         gThreshold        = [[cfg objectForKey:@"Threshold"]         floatValue];
            if ([cfg objectForKey:@"MenuFilterEnabled"]) gMenuFilterEnabled = [[cfg objectForKey:@"MenuFilterEnabled"] boolValue];
        }
    } @catch (id e) {}
}

// ---- 共享 pan delegate ----
@interface ChatSwipePanDelegate : NSObject <UIGestureRecognizerDelegate>
@end
@implementation ChatSwipePanDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end
static ChatSwipePanDelegate *gPanDelegate = nil;

// ---- 给输入框挂 pan 手势（仅挂一次） ----
static void chatswipe_attachIfNeeded(UIView *view) {
    if (!gEnabled || !view) return;
    if ([view isKindOfClass:[UITextView class]]) {
        if (!((UITextView *)view).isEditable) return;
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        if (tf.secureTextEntry || !tf.enabled) return;
    } else {
        return;
    }
    static const void *kAttached = &kAttached;
    if (objc_getAssociatedObject(view, kAttached)) return;
    objc_setAssociatedObject(view, kAttached, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:view action:@selector(chatswipe_handlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan  = NO;
    if (!gPanDelegate) gPanDelegate = [[ChatSwipePanDelegate alloc] init];
    pan.delegate = gPanDelegate;
    [view addGestureRecognizer:pan];
}

// ---- 动作：清空 / 粘贴 ----
static void chatswipe_clear(UIView *view) {
    @try {
        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)view;
            UITextRange *all = [tv textRangeFromPosition:tv.beginningOfDocument toPosition:tv.endOfDocument];
            if (all) [tv replaceRange:all withText:@""];
        } else if ([view isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)view;
            UITextRange *all = [tf textRangeFromPosition:tf.beginningOfDocument toPosition:tf.endOfDocument];
            if (all) [tf replaceRange:all withText:@""];
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
    } @catch (id e) {}
}

static void chatswipe_paste(UIView *view) {
    @try {
        NSString *pb = [UIPasteboard generalPasteboard].string;
        if (!pb || pb.length == 0) return;
        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)view;
            UITextRange *r = tv.selectedTextRange
                ?: [tv textRangeFromPosition:tv.endOfDocument toPosition:tv.endOfDocument];
            if (r) [tv replaceRange:r withText:pb];
        } else if ([view isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)view;
            UITextRange *r = tf.selectedTextRange
                ?: [tf textRangeFromPosition:tf.endOfDocument toPosition:tf.endOfDocument];
            if (r) [tf replaceRange:r withText:pb];
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
    } @catch (id e) {}
}

// ---- pan 回调 ----
@interface UIView (ChatSwipe)
- (void)chatswipe_handlePan:(UIPanGestureRecognizer *)pan;
@end
@implementation UIView (ChatSwipe)
- (void)chatswipe_handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateEnded) return;
    CGPoint t = [pan translationInView:self];
    CGFloat dx = t.x, dy = t.y;
    if (fabs(dx) <= fabs(dy)) return;
    if (fabs(dx) < gThreshold) return;
    if (dx < 0) { if (gClearEnabled)  chatswipe_clear(self);  }
    else       { if (gPasteEnabled)  chatswipe_paste(self);  }
}
@end

// ---- 编辑菜单三件套 Hook ----
%hook UITextView
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); }
    return r;
}
- (BOOL)resignFirstResponder {
    return %orig;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); }
}
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES;
    return NO;
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); }
    return r;
}
- (BOOL)resignFirstResponder {
    return %orig;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); }
}
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    // 密码框不强制复制/全选（防泄密），但粘贴仍允许
    if ((action == @selector(copy:) || action == @selector(selectAll:)) && self.secureTextEntry) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES;
    return NO;
}
%end

%ctor {
    chatswipe_loadConfig();
}

// =====================================================================
//  B. KbDock —— 键盘底部快捷条（全选 / 复制 / 粘贴）
//  基于 MyDock(com.ban.mydock) 作者 1.0 源码改造：
//   ① 删除「撤销」「收起键盘」 ② 新增「复制」 ③ 自绘「点状」图标（三个按钮统一为单个极小点）
//   ④ tintColor=labelColor → 自适应系统深浅色
//  Hook: UIKeyboardDockView -layoutSubviews
// =====================================================================

@interface UIKeyboardDockView : UIView
- (void)kb_haptic;
- (void)kb_selectAll;
- (void)kb_copy;
- (void)kb_paste;
@end

// ---- 自绘点状图标 ----
// 三个按钮统一为「单个居中极小点」（原先双点靠摆放方向区分，已取消）
// 画布 26x26，点径 ≈ 上一版虚线的一个点（1.5pt）
static CGFloat const kDotD = 1.5;   // 点直径（极小）

static UIImage *KbDotIcon(void) {
    static UIImage *cache = nil;   // 性能：只渲染一次，键盘复用时不再重绘
    if (cache) return cache;

    const CGFloat side = 26.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];

    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setFill];

        CGFloat c = side / 2.0;
        UIBezierPath *dot = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(c - kDotD / 2.0, c - kDotD / 2.0, kDotD, kDotD)];
        [dot fill];
    }];

    cache = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];   // 存入缓存
    return cache;
}

// ---- 按钮 ----
static UIButton *KbMakeButton(UIImage *icon, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:icon forState:UIControlStateNormal];
    b.tintColor = [UIColor labelColor];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor  constraintEqualToConstant:44].active = YES;  // 热区 44x44（点再小也点得准）
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    if ([self viewWithTag:9999]) return;  // 只加一次

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.tag = 9999;
    stackView.axis = UILayoutConstraintAxisHorizontal;
    stackView.distribution = UIStackViewDistributionEqualSpacing;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;

    // 按钮位置/功能不变（左→右 = 全选 / 复制 / 粘贴）；三个图标统一为单个点
    [stackView addArrangedSubview:KbMakeButton(KbDotIcon(), self, @selector(kb_selectAll))];
    [stackView addArrangedSubview:KbMakeButton(KbDotIcon(), self, @selector(kb_copy))];
    [stackView addArrangedSubview:KbMakeButton(KbDotIcon(), self, @selector(kb_paste))];

    [self addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stackView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor constant:-23],
        [stackView.widthAnchor    constraintEqualToAnchor:self.widthAnchor multiplier:0.55],
    ]];
}

%new
- (void)kb_haptic {
    // 性能：复用同一个触感发生器，避免每次点击都新建 + prepare 的开销
    static UIImpactFeedbackGenerator *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [g prepare];
    });
    [g impactOccurred];
}

%new
- (void)kb_selectAll {
    [self kb_haptic];
    [[UIApplication sharedApplication] sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil];
}

%new
- (void)kb_copy {
    [self kb_haptic];
    [[UIApplication sharedApplication] sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
}

%new
- (void)kb_paste {
    [self kb_haptic];
    [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
}

%end
