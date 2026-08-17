// ChatSwipe — 通用聊天输入框滑动手势 + 编辑菜单三件套（全选/复制/粘贴）
// 设计：app 无关。只操作「当前 first responder 的 UITextView/UITextField」+ UIPasteboard。
// 左滑 → 清空输入框；右滑 → 在光标处粘贴剪贴板。
// 单击/长按输入框弹出的编辑菜单 → 只保留 全选/复制/粘贴（按此顺序），其余（扫描文本 scanDocument:、
// 剪切、选择、替换、查找、翻译、分享、以及 App 自定义项 换行/全屏输入/#话题/搜一搜 等）一律移除。
//
// v1.5.0 精简版（老板拍板：放弃自绘菜单适配，只要三件套稳定 + 扫描文本必去掉）：
//   - 删掉全部探针（UIButton/UIMenuItem/didMoveToWindow/presentViewController）
//   - 删掉全部动态 hook（UIMenuController 全家 / 懒加载子类 / delegate hook / 交互期枚举 /
//     NSObject 全局 editMenuInteraction / textView:editMenuForTextRange / inputAssistantItem）
//   - 只保留编译期 %hook（与滑动功能同机制，ARM64e PAC 安全）：
//       1) canPerformAction:withSender: —— 三件套强制显示，其余 NO（含 scanDocument 扫描文本，必去掉）
//       2) editMenuInteraction:menuForConfiguration:suggestedActions: —— 对最终 UIMenu 过滤 + 排序
//       3) UIEditMenuInteraction updateVisibleMenu —— iOS16 系统菜单显示/更新时，KVC 过滤排序 _menu
//       4) buildMenuWithBuilder: —— iOS 13–15 旧路径兜底过滤
//   - 排序：全选(selectAll:) → 复制(copy:) → 粘贴(paste:)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ==================== 配置（可选 /var/mobile/Documents/chatswipe.plist） ====================
static BOOL     gEnabled     = YES;   // 总开关
static BOOL     gClearEnabled= YES;   // 左滑清空
static BOOL     gPasteEnabled= YES;   // 右滑粘贴
static CGFloat  gThreshold   = 45.0;  // 触发所需最小水平位移(pt)
static BOOL     gMenuFilterEnabled = YES; // 编辑菜单精简总开关（只留 全选/复制/粘贴）

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

// ==================== 编辑菜单三件套 ====================
// 白名单：仅允许 全选/复制/粘贴 出现在输入框菜单中（扫描文本 scanDocument: 不在白名单 → 必去掉）。
static BOOL chatmenu_isAllowedAction(SEL action) {
    if (action == @selector(selectAll:)) return YES;
    if (action == @selector(copy:))      return YES;
    if (action == @selector(paste:))     return YES;
    return NO;
}

// 过滤 + 排序 UIMenu：只保留白名单 UICommand（selectAll/copy/paste），丢弃 UIAction（App 自定义项）
// 与其余非白名单项（含扫描文本 scanDocument:）；白名单项按「全选 → 复制 → 粘贴」顺序重排；其他未知元素放末尾。
static id chatmenu_filterAndOrderMenu(id menu) {
    if (!menu) return nil;
    Class menuCls   = NSClassFromString(@"UIMenu");
    Class cmdCls    = NSClassFromString(@"UICommand");
    Class actionCls = NSClassFromString(@"UIAction");
    if (!menuCls || ![menu isKindOfClass:menuCls]) return menu; // 非 UIMenu 交给上层判断
    NSArray *children = [menu valueForKey:@"children"];
    if (!children || children.count == 0) return menu;

    NSMutableArray *whitelist = [NSMutableArray array]; // 白名单 UICommand（待排序）
    NSMutableArray *others    = [NSMutableArray array]; // 子菜单/未知元素（放末尾）
    for (id el in children) {
        if (menuCls && [el isKindOfClass:menuCls]) {
            id f = chatmenu_filterAndOrderMenu(el); // 递归子菜单
            if (f) [others addObject:f];
        } else if (cmdCls && [el isKindOfClass:cmdCls]) {
            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
            if (chatmenu_isAllowedAction(a)) {
                [whitelist addObject:el];
            }
            // 非白名单 UICommand（含 scanDocument 扫描文本）：丢弃
        } else if (actionCls && [el isKindOfClass:actionCls]) {
            // App 自定义 UIAction：丢弃
        } else {
            [others addObject:el]; // 其他未知元素保留
        }
    }

    // 排序：全选(selectAll:) → 复制(copy:) → 粘贴(paste:)
    NSArray *order = @[NSStringFromSelector(@selector(selectAll:)),
                       NSStringFromSelector(@selector(copy:)),
                       NSStringFromSelector(@selector(paste:))];
    NSMutableArray *sorted = [NSMutableArray array];
    for (NSString *selName in order) {
        for (id el in whitelist) {
            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
            if ([NSStringFromSelector(a) isEqualToString:selName]) {
                [sorted addObject:el];
                break;
            }
        }
    }
    for (id el in whitelist) { // 理论不会有的多余白名单项，兜底放后面
        if (![sorted containsObject:el]) [sorted addObject:el];
    }
    [sorted addObjectsFromArray:others];

    // 无变化时原样返回（避免无谓重建）
    BOOL changed = (sorted.count != children.count);
    if (!changed) {
        for (NSUInteger i = 0; i < children.count; i++) {
            if (children[i] != sorted[i]) { changed = YES; break; }
        }
    }
    if (!changed) return menu;
    return [menuCls performSelector:@selector(menuWithChildren:) withObject:sorted];
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

// ==================== 编辑菜单三件套 Hook（编译期 %hook，PAC 安全） ====================
// 1) canPerformAction: —— 三件套强制 YES，其余 NO（含 scanDocument 扫描文本/剪切/选择/替换/查找/翻译）
// 2) editMenuInteraction: —— iOS16 对最终 UIMenu 过滤 + 排序（全选→复制→粘贴）
// 3) UIEditMenuInteraction updateVisibleMenu —— iOS16 系统菜单显示/更新时 KVC 过滤排序（兜底系统路径）
// 4) buildMenuWithBuilder: —— iOS 13–15 旧路径兜底
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

// iOS 16 主拦截点（基类实例 + 子类未 override 的情形）：过滤 + 排序。
- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)configuration suggestedActions:(NSArray *)suggestedActions {
    if (!gMenuFilterEnabled) return %orig;
    id origMenu = %orig;
    return chatmenu_filterAndOrderMenu(origMenu);
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
    return chatmenu_filterAndOrderMenu(origMenu);
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

// v1.5.0：iOS16 系统菜单（UIEditMenuInteraction）显示/更新时，KVC 过滤排序 _menu。
// 只处理"含文本编辑白名单项"的菜单（避免误伤图片/链接长按等）；_menu 私有 ivar 取不到则自动跳过。
%hook UIEditMenuInteraction
- (void)updateVisibleMenu {
    %orig;
    if (!gMenuFilterEnabled) return;
    @try {
        id menu = [self valueForKey:@"_menu"];
        if (!menu) return;
        // 只处理含白名单项的菜单（文本编辑菜单），其他菜单原样放行
        BOOL hasWhitelist = NO;
        Class cmdCls = NSClassFromString(@"UICommand");
        NSArray *ch = [menu valueForKey:@"children"];
        for (id el in ch) {
            if (cmdCls && [el isKindOfClass:cmdCls]) {
                SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
                if (chatmenu_isAllowedAction(a)) { hasWhitelist = YES; break; }
            }
        }
        if (!hasWhitelist) return;
        id filtered = chatmenu_filterAndOrderMenu(menu);
        if (filtered != menu) {
            [self setValue:filtered forKey:@"_menu"];
            chatmenu_log(@"[editMenuUpdate] filtered+ordered");
        }
    } @catch (id e) {}
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
    chatmenu_log([NSString stringWithFormat:@"chatswipe v1.5.0 loaded %@", [NSDate date]]);
    // app 无关：只在「本 dylib 被注入的 app」内生效（TrollFools 决定注入哪个）。
}
