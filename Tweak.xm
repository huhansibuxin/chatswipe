// ChatSwipe — 通用聊天输入框滑动手势 + 编辑菜单精简
// 设计：app 无关。只操作「当前 first responder 的 UITextView/UITextField」+ UIPasteboard。
// 左滑 → 清空输入框；右滑 → 在光标处粘贴剪贴板。
// 单击/长按输入框弹出的编辑菜单 → 只保留 粘贴/复制/全选，去掉 App 自定义项
//（微信 #话题/搜一搜、QQ 换行/全屏输入、备忘录 格式/查找）与系统「扫描文本」(scanDocument:) 等。
//
// ⚠️ 稳定性铁律（老板实测教训，v1.1.0 → v1.2.8 多轮闪退后定稿）：
//   - 只允许编译期 %hook（Logos / MSHookMessageEx 底层，ARM64e PAC 安全，与滑动功能同机制）。
//   - 禁止任何运行时动态替换 IMP（method_setImplementation / imp_implementationWithBlock /
//     MSHookMessageEx 枚举 objc_getClassList 扫系统/框架类）—— 对 UIKit 系统内部类做动态替换
//     在 iOS16 ARM64e 下会 BRK 崩溃（v1.2.1/v1.2.4/v1.2.7/v1.2.8 全部因此闪退）。
//   - 加载/诊断日志一律写 App 沙盒 Documents（NSHomeDirectory()），严禁写 /var/jb/tmp ——
//     App 进程沙盒内 /var/jb/tmp 不可写，写了也看不到（此前"没有日志"即因此）。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ==================== 配置（可选 /var/mobile/Documents/chatswipe.plist） ====================
static BOOL     gEnabled     = YES;   // 总开关
static BOOL     gClearEnabled= YES;   // 左滑清空
static BOOL     gPasteEnabled= YES;   // 右滑粘贴
static CGFloat  gThreshold   = 45.0;  // 触发所需最小水平位移(pt)
static BOOL     gMenuFilterEnabled = YES; // 编辑菜单精简总开关（只留 粘贴/复制/全选）

// ==================== 诊断日志（写 App 沙盒 Documents，%ctor 先清空 = 清除上一版本日志） ====================
static void chatmenu_log(NSString *msg) {
    @try {
        NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                          stringByAppendingPathComponent:@"chatswipe.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"%@\n", msg] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh synchronizeFile];
            [fh closeFile];
        }
    } @catch (id e) {}
}

// ==================== 编辑菜单精简 ====================
// 白名单：仅允许 粘贴/复制/全选 出现在输入框菜单中。
static BOOL chatmenu_isAllowedAction(SEL action) {
    if (action == @selector(paste:))     return YES;
    if (action == @selector(copy:))      return YES;
    if (action == @selector(selectAll:)) return YES;
    return NO;
}

// 递归过滤 UIMenu：保留白名单 UICommand（paste/copy/selectAll），丢弃 UIAction（App 自定义项）
// 与其余非白名单项；无变化时原样返回（避免无谓重建）。
static id chatmenu_filterMenu(id menu) {
    if (!menu) return nil;
    Class menuCls   = NSClassFromString(@"UIMenu");
    Class cmdCls    = NSClassFromString(@"UICommand");
    Class actionCls = NSClassFromString(@"UIAction");
    if (!menuCls || ![menu isKindOfClass:menuCls]) return menu; // 非 UIMenu 交给上层判断
    NSArray *children = [menu valueForKey:@"children"];
    if (!children || children.count == 0) return menu;
    NSMutableArray *keep = [NSMutableArray array];
    BOOL changed = NO;
    for (id el in children) {
        if (menuCls && [el isKindOfClass:menuCls]) {
            id filtered = chatmenu_filterMenu(el); // 递归子菜单
            if (filtered) [keep addObject:filtered];
            else changed = YES;
        } else if (cmdCls && [el isKindOfClass:cmdCls]) {
            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
            if (chatmenu_isAllowedAction(a)) [keep addObject:el];
            else changed = YES;
        } else if (actionCls && [el isKindOfClass:actionCls]) {
            changed = YES; // App 自定义 UIAction：丢弃
        } else {
            [keep addObject:el]; // 其他未知元素保留
        }
    }
    if (!changed) return menu;
    return [menuCls performSelector:@selector(menuWithChildren:) withObject:keep];
}

static void chatswipe_loadConfig() {
    @try {
        NSString *path = @"/var/mobile/Documents/chatswipe.plist";
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if (cfg) {
            if ([cfg objectForKey:@"Enabled"])      gEnabled      = [[cfg objectForKey:@"Enabled"]      boolValue];
            if ([cfg objectForKey:@"ClearEnabled"])  gClearEnabled = [[cfg objectForKey:@"ClearEnabled"]  boolValue];
            if ([cfg objectForKey:@"PasteEnabled"])  gPasteEnabled = [[cfg objectForKey:@"PasteEnabled"]  boolValue];
            if ([cfg objectForKey:@"Threshold"])     gThreshold    = [[cfg objectForKey:@"Threshold"]     floatValue];
            if ([cfg objectForKey:@"MenuFilterEnabled"]) gMenuFilterEnabled = [[cfg objectForKey:@"MenuFilterEnabled"] boolValue];
        }
    } @catch (id e) {}
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
    // 只给"可编辑"输入区挂手势：跳过只读展示文本框（如消息气泡，横滑会清掉其显示文本）
    // 与密码框（secureTextEntry），避免误清/误粘敏感内容。
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
    pan.cancelsTouchesInView = NO;   // 不取消触摸，避免破坏点选/拖选
    pan.delaysTouchesBegan  = NO;
    if (!gPanDelegate) gPanDelegate = [[ChatSwipePanDelegate alloc] init];
    pan.delegate = gPanDelegate;
    [view addGestureRecognizer:pan];
}

// ==================== 动作：清空 / 粘贴 ====================
static void chatswipe_clear(UIView *view) {
    @try {
        // 统一走 replaceRange：UITextView 会自动触发 textViewDidChange:（勿手调，避免重复触发）；
        // UITextField 程序化编辑不会自动发 editingChanged，故补一次（且仅一次）。
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
        // 统一走 replaceRange：有选区则替换、无选区(或 nil)则插到末尾/光标处。
        // UITextView 靠 replaceRange 自动触发 textViewDidChange:（勿手调）；
        // UITextField 程序化编辑不会自动发 editingChanged，故补一次（且仅一次）。
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

// ==================== 编辑菜单精简 Hook（编译期 %hook，PAC 安全，禁动态替换） ====================
// 拦截点：
//   1) canPerformAction:withSender: —— 控制标准动作是否显示：三件套强制 YES，其余 NO
//      （含系统「扫描文本」scanDocument:、剪切/选择/替换/查找/翻译 等）。
//   2) editMenuInteraction:menuForConfiguration:suggestedActions: —— iOS16 主拦截点，
//      对最终 UIMenu 递归过滤：保留白名单 UICommand，丢弃 UIAction（App 自定义项）。
//   3) buildMenuWithBuilder: —— iOS 13–15 旧路径兜底（UIMenuController + UIMenuBuilder）。
// 仅 hook 输入框基类（UITextView/UITextField），与滑动功能同一 %hook 块，无任何运行时动态替换。
%hook UITextView
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) chatswipe_attachIfNeeded(self);
    return r;
}
// 兜底：输入框显示到窗口即挂手势，不依赖它先成为 first responder。
- (void)didMoveToWindow {
    %orig;
    if (self.window) chatswipe_attachIfNeeded(self);
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES; // 三件套：强制显示 + 可用
    return NO;                                        // 其余（含 scanDocument 扫描文本）一律不显示
}

// iOS 16 主拦截点：App 自定义项在这里以 UIAction 追加。对最终 UIMenu 递归过滤。
- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)configuration suggestedActions:(NSArray *)suggestedActions {
    if (!gMenuFilterEnabled) return %orig;
    id origMenu = %orig;
    return chatmenu_filterMenu(origMenu);
}

// 兜底：iOS 13–15 旧路径（UIMenuController + UIMenuBuilder）。
- (void)buildMenuWithBuilder:(id)builder {
    %orig;
    if (!gMenuFilterEnabled) return;
    if (@available(iOS 13.0, *)) {
        if ([builder respondsToSelector:@selector(replaceChildrenOfMenuForIdentifier:withChildren:)]) {
            @try {
                NSString *editId = @"com.apple.menu.identifier.edit";
                Class cmdCls = NSClassFromString(@"UICommand");
                Class menuCls = NSClassFromString(@"UIMenu");
                id block = ^NSArray *(NSArray *children) {
                    NSMutableArray *keep = [NSMutableArray array];
                    for (id el in children) {
                        if (menuCls && [el isKindOfClass:menuCls]) continue;
                        if (cmdCls && [el isKindOfClass:cmdCls]) {
                            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
                            if (chatmenu_isAllowedAction(a)) [keep addObject:el];
                        }
                    }
                    return keep;
                };
                ((void (*)(id, SEL, id, id))objc_msgSend)(builder,
                    @selector(replaceChildrenOfMenuForIdentifier:withChildren:), editId, block);
            } @catch (id e) {}
        }
    }
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) chatswipe_attachIfNeeded(self);
    return r;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) chatswipe_attachIfNeeded(self);
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    // 密码框不强制 复制/全选（防泄密），但 粘贴 仍允许
    if ((action == @selector(copy:) || action == @selector(selectAll:)) && self.secureTextEntry) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES; // 三件套：强制显示 + 可用
    return NO;                                        // 其余（含 scanDocument 扫描文本）一律不显示
}

- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)configuration suggestedActions:(NSArray *)suggestedActions {
    if (!gMenuFilterEnabled) return %orig;
    id origMenu = %orig;
    return chatmenu_filterMenu(origMenu);
}

- (void)buildMenuWithBuilder:(id)builder {
    %orig;
    if (!gMenuFilterEnabled) return;
    if (@available(iOS 13.0, *)) {
        if ([builder respondsToSelector:@selector(replaceChildrenOfMenuForIdentifier:withChildren:)]) {
            @try {
                NSString *editId = @"com.apple.menu.identifier.edit";
                Class cmdCls = NSClassFromString(@"UICommand");
                Class menuCls = NSClassFromString(@"UIMenu");
                id block = ^NSArray *(NSArray *children) {
                    NSMutableArray *keep = [NSMutableArray array];
                    for (id el in children) {
                        if (menuCls && [el isKindOfClass:menuCls]) continue;
                        if (cmdCls && [el isKindOfClass:cmdCls]) {
                            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
                            if (chatmenu_isAllowedAction(a)) [keep addObject:el];
                        }
                    }
                    return keep;
                };
                ((void (*)(id, SEL, id, id))objc_msgSend)(builder,
                    @selector(replaceChildrenOfMenuForIdentifier:withChildren:), editId, block);
            } @catch (id e) {}
        }
    }
}
%end

%ctor {
    chatswipe_loadConfig();
    // 清除上一版本日志 + 写加载标记（写 App 沙盒 Documents，SSH 可 cat：
    //   /var/mobile/Containers/Data/Application/<App-UUID>/Documents/chatswipe.log）
    @try {
        NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                          stringByAppendingPathComponent:@"chatswipe.log"];
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
    chatmenu_log([NSString stringWithFormat:@"chatswipe v1.3.0 loaded %@", [NSDate date]]);
    // app 无关：只在「本 dylib 被注入的 app」内生效（TrollFools 决定注入哪个）。
}
