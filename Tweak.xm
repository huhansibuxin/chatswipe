// ChatSwipe — 通用聊天输入框滑动手势
// 设计：app 无关。只操作「当前 first responder 的 UITextView/UITextField」+ UIPasteboard。
// 左滑 → 清空输入框；右滑 → 在光标处粘贴剪贴板。
// 通过 TrollFools 把本 dylib 注入目标 app 即可生效（filter plist 仅用于 dpkg 安装时限定范围）。

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

// 编辑菜单白名单：仅允许这三类动作出现在输入框长按/单击菜单中。
// 其余（剪切、选择、替换、查找、翻译、分享、以及系统"扫描文本" scanDocument: 等）+ App 自定义项
//（微信 #话题/搜一搜、QQ 换行/全屏输入、备忘录 格式/查找）一律移除。
static BOOL chatmenu_isAllowedAction(SEL action) {
    if (action == @selector(paste:))     return YES;
    if (action == @selector(copy:))      return YES;
    if (action == @selector(selectAll:)) return YES;
    return NO;
}

// 递归过滤 UIMenu：保留白名单 UICommand（paste/copy/selectAll），丢弃 UIAction（App 自定义项）
// 以及子菜单中其余非白名单项；无变化时原样返回（避免无谓重建）。
static id chatmenu_filterMenu(id menu) {
    if (!menu) return nil;
    Class menuCls   = NSClassFromString(@"UIMenu");
    Class cmdCls    = NSClassFromString(@"UICommand");
    Class actionCls = NSClassFromString(@"UIAction");
    if (!menuCls || ![menu isKindOfClass:menuCls]) return menu; // 非 UIMenu（如单个 UICommand）交给上层判断
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

// ==================== 动态 hook 文本框子类（App 常自定义子类，如微信 WCInputTextView） ====================
// Logos %hook 仅替换基类方法。若 App 在 UITextView/UITextField 的【子类】上重写
// canPerformAction: / editMenuInteraction:...，基类 hook 会被绕过 → 菜单毫无变化（v1.1.1 实测如此）。
// 故在加载时枚举所有子类，对“自身重写”了目标方法的子类逐一替换 IMP，并捕获其【原 IMP】。
// 用 imp_implementationWithBlock 闭包捕获各自 orig，天然兼容 KVO 子类（继承到被替换的 IMP）。

static NSMutableSet *gHookedClasses = nil;

static BOOL chatmenu_classOverridesSelector(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    if (methods) free(methods);
    return found;
}

static void chatmenu_hookTextViewSubclasses() {
    static SEL editSel = NULL, canSel = NULL;
    static Class tvCls = Nil, tfCls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        editSel = @selector(editMenuInteraction:menuForConfiguration:suggestedActions:);
        canSel  = @selector(canPerformAction:withSender:);
        tvCls = [UITextView class];
        tfCls = [UITextField class];
        gHookedClasses = [NSMutableSet set];
    });
    if (!tvCls || !tfCls) return;

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (unsigned)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        if (cls == tvCls || cls == tfCls) continue;                 // 基类交给 Logos %hook
        BOOL isTV = [cls isSubclassOfClass:tvCls];
        BOOL isTF = [cls isSubclassOfClass:tfCls];
        if (!isTV && !isTF) continue;

        NSString *key = [NSString stringWithUTF8String:class_getName(cls)];
        if ([gHookedClasses containsObject:key]) continue;          // 已 hook，防重复替换导致递归

        // 1) editMenuInteraction:（iOS 16 主拦截点，App 自定义项在此以 UIAction 追加）
        if (chatmenu_classOverridesSelector(cls, editSel)) {
            Method m = class_getInstanceMethod(cls, editSel);
            IMP orig = method_getImplementation(m);
            IMP repl = imp_implementationWithBlock(^id(id self, id interaction, id config, NSArray *suggested) {
                if (!gMenuFilterEnabled) {
                    return ((id (*)(id, SEL, id, id, NSArray *))orig)(self, editSel, interaction, config, suggested);
                }
                id menu = ((id (*)(id, SEL, id, id, NSArray *))orig)(self, editSel, interaction, config, suggested);
                return chatmenu_filterMenu(menu);
            });
            method_setImplementation(m, repl);
            [gHookedClasses addObject:key];
        }

        // 2) canPerformAction:（控制标准动作 粘贴/复制/全选 是否进入 suggestedActions）
        if (chatmenu_classOverridesSelector(cls, canSel)) {
            Method m = class_getInstanceMethod(cls, canSel);
            IMP orig = method_getImplementation(m);
            IMP repl = imp_implementationWithBlock(^BOOL(id self, SEL action, id sender) {
                if (!gMenuFilterEnabled) {
                    return ((BOOL (*)(id, SEL, SEL, id))orig)(self, canSel, action, sender);
                }
                // 密码框放行 复制/全选（防泄密）；其余三件套强制显示，不在白名单一律 NO
                if (isTF && (action == @selector(copy:) || action == @selector(selectAll:)) &&
                    ((UITextField *)self).secureTextEntry) {
                    return ((BOOL (*)(id, SEL, SEL, id))orig)(self, canSel, action, sender);
                }
                if (chatmenu_isAllowedAction(action)) return YES;
                return NO;
            });
            method_setImplementation(m, repl);
            [gHookedClasses addObject:key];
        }
    }
    free(classes);
}

// ==================== 精准 hook 输入框 edit menu 的 delegate（不碰 NSObject） ====================
// iOS 16 的 UIEditMenuInteraction delegate 通常是 App 的 VC/Coordinator，不是输入框本身，
// 所以挂在 UITextView/UITextField 上的 editMenuInteraction:... 不会被调用。
// 这里只针对"输入框"：从其内部 editMenuInteraction 拿到真正的 delegate 对象，
// 仅替换【那个 delegate 类】的 editMenuInteraction:menuForConfiguration:suggestedActions:，
// 绝不动 NSObject，也不会影响其他对象。内部仍用 interaction.view 判断关联的是否为输入框。
static void chatmenu_hookEditMenuDelegateForInput(id input) {
    if (!gMenuFilterEnabled || !input) return;
    if (![input isKindOfClass:[UITextView class]] && ![input isKindOfClass:[UITextField class]]) return;

    id interaction = nil;
    @try {
        if ([input respondsToSelector:@selector(editMenuInteraction)]) {
            interaction = ((id (*)(id, SEL))objc_msgSend)(input, @selector(editMenuInteraction));
        }
        if (!interaction) interaction = [input valueForKey:@"_editMenuInteraction"];
    } @catch (id e) {}

    if (!interaction || ![interaction respondsToSelector:@selector(delegate)]) return;
    id delegate = ((id (*)(id, SEL))objc_msgSend)(interaction, @selector(delegate));
    if (!delegate) return;

    Class delegateClass = [delegate class];
    // 输入框本身（或其子类）由 Logos %hook 处理，跳过
    if ([delegateClass isSubclassOfClass:[UITextView class]] ||
        [delegateClass isSubclassOfClass:[UITextField class]]) {
        return;
    }

    NSString *key = [NSString stringWithFormat:@"editmenu_%s", class_getName(delegateClass)];
    if ([gHookedClasses containsObject:key]) return;   // 已处理，防递归/重复

    SEL editSel = @selector(editMenuInteraction:menuForConfiguration:suggestedActions:);
    if (!chatmenu_classOverridesSelector(delegateClass, editSel)) {
        [gHookedClasses addObject:key]; // 标记已检查，避免重复探测
        return;
    }

    Method m = class_getInstanceMethod(delegateClass, editSel);
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^id(id self, id interaction, id config, NSArray *suggested) {
        if (!gMenuFilterEnabled) {
            return ((id (*)(id, SEL, id, id, NSArray *))orig)(self, editSel, interaction, config, suggested);
        }
        id menu = ((id (*)(id, SEL, id, id, NSArray *))orig)(self, editSel, interaction, config, suggested);
        // 只过滤"关联输入框"的编辑菜单；其他菜单（图片/链接长按等）原样放行
        id view = ((id (*)(id, SEL))objc_msgSend)(interaction, @selector(view));
        if (view && ([view isKindOfClass:[UITextView class]] || [view isKindOfClass:[UITextField class]])) {
            return chatmenu_filterMenu(menu);
        }
        return menu;
    });
    method_setImplementation(m, repl);
    [gHookedClasses addObject:key];
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

// ==================== 编辑菜单精简（老板需求） ====================
// 点击/长按输入框弹出的编辑菜单，各 App 内容不一：微信 #话题/搜一搜、QQ 换行/全屏输入、
// 备忘录 格式/查找，以及系统"扫描文本"(scanDocument:)。统一成只显示三项：
//   粘贴(paste:) / 复制(copy:) / 全选(selectAll:)
// iOS 16 关键点：UIMenuController 已被 UIEditMenuInteraction 取代。App 自定义项（#话题/搜一搜/换行）
// 是 App 在 delegate 方法 editMenuInteraction:menuForConfiguration:suggestedActions: 里以 UIAction
// 追加到系统 suggestedActions 之后的，完全不经过 canPerformAction:。所以拦截点必须是：
//   1) canPerformAction:withSender: —— 控制系统标准动作（paste/copy/cut/selectAll 等）是否进入
//      suggestedActions；我们强制三件套为 YES、其余(NO)（含扫描文本 scanDocument 不在白名单）。
//   2) editMenuInteraction:menuForConfiguration:suggestedActions: —— 对最终 UIMenu 递归过滤，
//      保留白名单 UICommand(paste/copy/selectAll)，丢弃所有 UIAction（即 App 自定义项）。
//   3) buildMenuWithBuilder: —— iOS 13–15 旧路径兜底（UIMenuController + UIMenuBuilder）。
// 只 hook 输入框(UITextView/UITextField)，避免误伤 App 其他菜单（如长按消息气泡的 转发/删除）。
// 本 dylib 由 TrollFools 注入目标 App，故仅在被注入 App 内生效（不注入 SpringBoard）。

%hook UITextView
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES; // 三件套：强制显示 + 可用（不依赖系统当前选中态）
    return NO;                                        // 其余（含 scanDocument 扫描文本）一律不显示
}

// iOS 16 主拦截点：App 自定义项在这里以 UIAction 追加。对最终 UIMenu 递归过滤。
- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)configuration suggestedActions:(NSArray *)suggestedActions {
    if (!gMenuFilterEnabled) return %orig;
    id origMenu = %orig;
    return chatmenu_filterMenu(origMenu);
}

// 兜底：iOS 13–15 旧路径（UIMenuController + UIMenuBuilder）；iOS 16 多走上面 editMenuInteraction。
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

// ==================== Hook：输入框成为第一响应者时挂手势 ====================
%hook UITextView
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); chatmenu_hookEditMenuDelegateForInput(self); }
    return r;
}
// 兜底：输入框显示到窗口即挂手势，不依赖它先成为 first responder。
// 否则首次打开聊天页、键盘未弹出时输入框已可见但未 becomeFirstResponder，手势漏挂 → 首次滑动无效。
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); chatmenu_hookEditMenuDelegateForInput(self); }
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); chatmenu_hookEditMenuDelegateForInput(self); }
    return r;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); chatmenu_hookEditMenuDelegateForInput(self); }
}
%end

%ctor {
    chatswipe_loadConfig();
    // 动态 hook 文本框子类：基类 + 未重写方法的子类由 Logos %hook 覆盖；
    // 重写过的子类（如微信 WCInputTextView）需逐一替换 IMP，否则菜单无变化。
    chatmenu_hookTextViewSubclasses();
    // 二次扫描：捕获 %ctor 时尚未 realize 的懒加载子类（部分 App 延后注册类）。
    // gHookedClasses 防重复；重复进入会因 method_setImplementation 把 block 当 orig 而递归爆栈。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        chatmenu_hookTextViewSubclasses();
    });
    // 加载验证：写文件标记，确认 dylib 被 TrollFools 注入并加载（iOS 16 rootless 世界 /var/jb/tmp 可写）。
    // 每次新版本覆盖写入（不清除旧日志的话多版本叠加难以辨认）。
    // 设备端 `cat /var/jb/tmp/chatswipe_loaded.log` 能看到时间戳即说明加载成功；看不到则 dylib 没注入。
    @try {
        NSString *path = @"/var/jb/tmp/chatswipe_loaded.log";
        NSString *msg = [NSString stringWithFormat:@"chatswipe v1.2.0 loaded %@\n", [NSDate date]];
        [msg writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
    // app 无关：只在「本 dylib 被注入的 app」内生效（TrollFools 决定注入哪个）。
}
