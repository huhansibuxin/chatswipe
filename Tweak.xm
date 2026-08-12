// ChatSwipe — 通用聊天输入框滑动手势
// 设计：app 无关。只操作「当前 first responder 的 UITextView/UITextField」+ UIPasteboard。
// 左滑 → 清空输入框；右滑 → 在光标处粘贴剪贴板。
// 通过 TrollFools 把本 dylib 注入目标 app 即可生效（filter plist 仅用于 dpkg 安装时限定范围）。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

// ==================== 配置（可选 /var/mobile/Documents/chatswipe.plist） ====================
static BOOL     gEnabled     = YES;   // 总开关
static BOOL     gClearEnabled= YES;   // 左滑清空
static BOOL     gPasteEnabled= YES;   // 右滑粘贴
static CGFloat  gThreshold   = 60.0;  // 触发所需最小水平位移(pt)

static void chatswipe_loadConfig() {
    @try {
        NSString *path = @"/var/mobile/Documents/chatswipe.plist";
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if (cfg) {
            if ([cfg objectForKey:@"Enabled"])      gEnabled      = [[cfg objectForKey:@"Enabled"]      boolValue];
            if ([cfg objectForKey:@"ClearEnabled"])  gClearEnabled = [[cfg objectForKey:@"ClearEnabled"]  boolValue];
            if ([cfg objectForKey:@"PasteEnabled"])  gPasteEnabled = [[cfg objectForKey:@"PasteEnabled"]  boolValue];
            if ([cfg objectForKey:@"Threshold"])     gThreshold    = [[cfg objectForKey:@"Threshold"]     floatValue];
        }
    } @catch (...) {}
}

// ==================== 共享 pan delegate：允许与原生文本选择手势并存 ====================
@interface ChatSwipePanDelegate : NSObject <UIGestureRecognizerDelegate>
@end
@implementation ChatSwipePanDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES; // 不抢原生手势，只在 Ended 时按阈值决定要不要动作
}
@end
static ChatSwipePanDelegate *gPanDelegate = nil;

// ==================== 给输入框挂 pan 手势（仅挂一次） ====================
static void chatswipe_attachIfNeeded(UIView *view) {
    if (!gEnabled || !view) return;
    static const void *kAttached = &kAttached;
    if (objc_getAssociatedObject(view, kAttached)) return;
    objc_setAssociatedObject(view, kAttached, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:view action:@selector(chatswipe_handlePan:)];
    pan.cancelsTouchesInView = NO;   // 不取消触摸，避免破坏点选/拖选
    pan.delaysTouchesBegan  = NO;
    if (!gPanDelegate) gPanDelegate = [[ChatSwipePanDelegate alloc] init];
    pan.delegate = gPanDelegate;
    [view addGestureRecognizer:pan];
}

// ==================== 动作：清空 / 粘贴 ====================
static void chatswipe_clear(UIView *view) {
    @try {
        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)view;
            tv.text = @"";
            if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)])
                [tv.delegate textViewDidChange:tv];
        } else if ([view isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)view;
            tf.text = @"";
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
    } @catch (...) {}
}

static void chatswipe_paste(UIView *view) {
    @try {
        NSString *pb = [UIPasteboard generalPasteboard].string;
        if (!pb || pb.length == 0) return;
        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)view;
            if (tv.selectedTextRange)
                [tv replaceRange:tv.selectedTextRange withText:pb];
            else
                tv.text = [tv.text stringByAppendingString:pb];
            if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)])
                [tv.delegate textViewDidChange:tv];
        } else if ([view isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)view;
            if (tf.selectedTextRange)
                [tf replaceRange:tf.selectedTextRange withText:pb];
            else
                tf.text = [tf.text stringByAppendingString:pb];
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
    } @catch (...) {}
}

// ==================== pan 回调（挂在 UIView 上，所有输入框都能响应） ====================
@interface UIView (ChatSwipe)
- (void)chatswipe_handlePan:(UIPanGestureRecognizer *)pan;
@end
@implementation UIView (ChatSwipe)
- (void)chatswipe_handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateEnded) return;
    CGPoint t = [pan translationInView:self];
    CGFloat dx = t.x, dy = t.y;
    if (fabs(dx) <= fabs(dy)) return;       // 不够水平
    if (fabs(dx) < gThreshold) return;      // 位移太短
    if (dx < 0) { if (gClearEnabled)  chatswipe_clear(self);  }
    else       { if (gPasteEnabled)  chatswipe_paste(self);  }
}
@end

// ==================== Hook：输入框成为第一响应者时挂手势 ====================
%hook UITextView
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) chatswipe_attachIfNeeded(self);
    return r;
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) chatswipe_attachIfNeeded(self);
    return r;
}
%end

%ctor {
    chatswipe_loadConfig();
    // app 无关：只在「本 dylib 被注入的 app」内生效（TrollFools 决定注入哪个）。
}
