// ChatSwipe — 通用聊天输入框滑动手势 + 编辑菜单三件套（全选/复制/粘贴）
// 设计：app 无关。只操作「当前 first responder 的 UITextView/UITextField」+ UIPasteboard。
// 左滑 → 清空输入框；右滑 → 在光标处粘贴剪贴板。
// 单击/长按输入框弹出的编辑菜单 → 只保留 全选/复制/粘贴（按此顺序），其余（扫描文本 scanDocument:、
// 剪切、选择、替换、查找、翻译、分享、以及 App 自定义项 换行/全屏输入/#话题/搜一搜 等）一律移除。
//
// v1.5.4 稳定排序版（真因修复）：
//   实测（v1.5.3 日志）QQ 走**现代 UIEditMenuInteraction**，但其 delegate 不是输入框本身（是 App 自己的类），
//   所以 hook UITextView 的 editMenuInteraction: 永不触发、排序从未执行。
//   修复：hook UIEditMenuInteraction 的 setDelegate:，捕获真实 delegate 类（仅 App 类→PAC 安全），
//   用 MSHookMessageEx 替换其 editMenuInteraction:menuForConfiguration:suggestedActions: → 过滤+排序（全选→复制→粘贴）。
//   同时保留 legacy UIMenuController 注入兜底（兼容仍走老 API 的 App），以及 canPerformAction 三件套+扫描文本必去掉。

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

// ==================== 菜单状态 ====================
static BOOL gInjectingCustom = NO;          // 正在构建老式 UIMenuController（legacy 路径）时置 YES
static __weak UIResponder *gCurrentInput = nil; // 当前 first responder（仅记可编辑输入框）

// 我们注入的自定义 action（legacy 路径用，避免与系统 copy:/paste:/selectAll: 冲突）
static SEL gSelSelectAll = nil;
static SEL gSelCopy       = nil;
static SEL gSelPaste      = nil;

// ==================== 现代路径 delegate hook 状态 ====================
static NSMutableDictionary *gEditMenuOrig = nil; // 按类名存 delegate 原 editMenuInteraction IMP
static NSMutableSet *gEditMenuHooked = nil;
static NSMutableDictionary *gTextMenuOrig = nil; // 按类名存 delegate 原 textView:editMenuForTextRange: IMP
static NSMutableSet *gTextMenuHooked = nil;

// ==================== 诊断日志（写 App 沙盒 Documents，%ctor 先清空） ====================
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
static BOOL chatmenu_isAllowedAction(SEL action) {
    if (action == @selector(selectAll:)) return YES;
    if (action == @selector(copy:))      return YES;
    if (action == @selector(paste:))     return YES;
    return NO;
}

// 过滤 + 排序 UIMenu：只保留白名单 UICommand（selectAll/copy/paste），丢弃 UIAction（App 自定义项）
// 与其余非白名单项（含扫描文本 scanDocument:）；白名单项按「全选 → 复制 → 粘贴」顺序重排。
static id chatmenu_filterAndOrderMenu(id menu) {
    if (!menu) return nil;
    Class menuCls   = NSClassFromString(@"UIMenu");
    Class cmdCls    = NSClassFromString(@"UICommand");
    Class actionCls = NSClassFromString(@"UIAction");
    if (!menuCls || ![menu isKindOfClass:menuCls]) return menu;
    NSArray *children = [menu valueForKey:@"children"];
    if (!children || children.count == 0) return menu;

    NSMutableArray *whitelist = [NSMutableArray array];
    NSMutableArray *others    = [NSMutableArray array];
    for (id el in children) {
        if (menuCls && [el isKindOfClass:menuCls]) {
            id f = chatmenu_filterAndOrderMenu(el);
            if (f) [others addObject:f];
        } else if (cmdCls && [el isKindOfClass:cmdCls]) {
            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
            if (chatmenu_isAllowedAction(a)) [whitelist addObject:el];
        } else if (actionCls && [el isKindOfClass:actionCls]) {
            // App 自定义 UIAction：丢弃
        } else {
            [others addObject:el];
        }
    }

    NSArray *order = @[NSStringFromSelector(@selector(selectAll:)),
                       NSStringFromSelector(@selector(copy:)),
                       NSStringFromSelector(@selector(paste:))];
    NSMutableArray *sorted = [NSMutableArray array];
    for (NSString *selName in order) {
        for (id el in whitelist) {
            SEL a = ((SEL (*)(id, SEL))objc_msgSend)(el, @selector(action));
            if ([NSStringFromSelector(a) isEqualToString:selName]) { [sorted addObject:el]; break; }
        }
    }
    for (id el in whitelist) { if (![sorted containsObject:el]) [sorted addObject:el]; }
    [sorted addObjectsFromArray:others];

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

// App 类判定：有 image 且属于系统/框架 → NO；无 image（运行时动态类，如 QQ 的 _qlvr_obj_hook_）→ 按 App 类放行。
static BOOL chatmenu_isAppClass(Class cls) {
    if (!cls) return NO;
    const char *img = class_getImageName(cls);
    if (!img || !*img) return YES; // 动态类（无 image）按 App 类处理
    NSString *s = [NSString stringWithUTF8String:img];
    if ([s containsString:@"/System/Library/"] ||
        [s containsString:@"/Library/"] ||
        [s containsString:@"/usr/"] ||
        [s containsString:@"/var/jb/Library/"] ||
        [s containsString:@"/var/jb/usr/"] ||
        [s containsString:@"/Applications/"]) {
        return NO;
    }
    return YES;
}

// 现代路径 replacement：调用 delegate 原 editMenuInteraction: → 过滤 + 排序。
static id chatmenu_editMenuReplacement(id self, SEL _cmd, id interaction, id config, NSArray *suggested) {
    Class cls = object_getClass(self);
    IMP orig = NULL;
    Class sc = cls;
    while (sc) {
        NSValue *v = [gEditMenuOrig objectForKey:NSStringFromClass(sc)];
        if (v) { orig = (IMP)[v pointerValue]; break; }
        sc = class_getSuperclass(sc);
    }
    id origMenu = nil;
    if (orig) {
        id (*fn)(id, SEL, id, id, NSArray *) = (id (*)(id, SEL, id, id, NSArray *))orig;
        origMenu = fn(self, _cmd, interaction, config, suggested);
    } else {
        struct objc_super sup = { self, class_getSuperclass(cls) };
        id (*fn)(struct objc_super *, SEL, id, id, NSArray *) =
            (id (*)(struct objc_super *, SEL, id, id, NSArray *))objc_msgSendSuper;
        origMenu = fn(&sup, _cmd, interaction, config, suggested);
    }
    if (!gMenuFilterEnabled) return origMenu;
    chatmenu_log([NSString stringWithFormat:@"[emi] replacement hit self=%@ menu=%@",
                  NSStringFromClass(cls), origMenu ? @"nonnil" : @"nil"]);
    return chatmenu_filterAndOrderMenu(origMenu);
}

// 文本视图 delegate 路径 replacement：textView:editMenuForTextRange:suggestedActions:
// iOS16 文本视图 delegate 可在此返回 UIMenu（菜单内容与顺序由它决定）→ 过滤 + 排序。
static id chatmenu_textMenuReplacement(id self, SEL _cmd, id tv, id range, NSArray *suggested) {
    Class cls = object_getClass(self);
    IMP orig = NULL;
    Class sc = cls;
    while (sc) {
        NSValue *v = [gTextMenuOrig objectForKey:NSStringFromClass(sc)];
        if (v) { orig = (IMP)[v pointerValue]; break; }
        sc = class_getSuperclass(sc);
    }
    id origMenu = nil;
    if (orig) {
        id (*fn)(id, SEL, id, id, NSArray *) = (id (*)(id, SEL, id, id, NSArray *))orig;
        origMenu = fn(self, _cmd, tv, range, suggested);
    } else {
        struct objc_super sup = { self, class_getSuperclass(cls) };
        id (*fn)(struct objc_super *, SEL, id, id, NSArray *) =
            (id (*)(struct objc_super *, SEL, id, id, NSArray *))objc_msgSendSuper;
        origMenu = fn(&sup, _cmd, tv, range, suggested);
    }
    if (!gMenuFilterEnabled) return origMenu;
    chatmenu_log([NSString stringWithFormat:@"[tvEditMenu] hit self=%@ menu=%@",
                  NSStringFromClass(cls), origMenu ? @"nonnil" : @"nil"]);
    if (origMenu) return chatmenu_filterAndOrderMenu(origMenu);
    // orig 返回 nil → UIKit 用 suggestedActions 自建菜单；我们从中过滤+排序白名单项后组 UIMenu。
    if (suggested && suggested.count) {
        Class cmdCls = NSClassFromString(@"UICommand");
        Class actCls = NSClassFromString(@"UIAction");
        NSMutableArray *keep = [NSMutableArray array];
        for (id a in suggested) {
            if (cmdCls && [a isKindOfClass:cmdCls]) {
                SEL act = ((SEL (*)(id, SEL))objc_msgSend)(a, @selector(action));
                if (chatmenu_isAllowedAction(act)) [keep addObject:a];
            } else if (actCls && [a isKindOfClass:actCls]) {
                // App 自定义 UIAction：丢弃
            } else {
                if (chatmenu_isAllowedAction(((SEL (*)(id, SEL))objc_msgSend)(a, @selector(action)))) [keep addObject:a];
            }
        }
        NSArray *order = @[NSStringFromSelector(@selector(selectAll:)),
                           NSStringFromSelector(@selector(copy:)),
                           NSStringFromSelector(@selector(paste:))];
        NSMutableArray *ordered = [NSMutableArray array];
        for (NSString *sn in order) {
            for (id a in keep) {
                SEL act = ((SEL (*)(id, SEL))objc_msgSend)(a, @selector(action));
                if ([NSStringFromSelector(act) isEqualToString:sn]) { [ordered addObject:a]; break; }
            }
        }
        for (id a in keep) { if (![ordered containsObject:a]) [ordered addObject:a]; }
        Class menuCls = NSClassFromString(@"UIMenu");
        if (menuCls && ordered.count) return [menuCls performSelector:@selector(menuWithChildren:) withObject:ordered];
    }
    return nil;
}

// ==================== 共享 pan delegate ====================
@interface ChatSwipePanDelegate : NSObject <UIGestureRecognizerDelegate>
@end
@implementation ChatSwipePanDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end
static ChatSwipePanDelegate *gPanDelegate = nil;

// ==================== 给输入框挂 pan 手势（仅挂一次） ====================
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

// ==================== 动作：清空 / 粘贴 ====================
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

// ==================== pan 回调 ====================
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

// ==================== 编辑菜单三件套 Hook ====================
// canPerformAction：保留三件套（modern 路径），抑制其余（含 scanDocument 扫描文本必去掉）。
// legacy 路径由 gInjectingCustom 分支抑制系统三件套、仅留注入的自定义项。
%hook UITextView
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); gCurrentInput = self; }
    return r;
}
- (BOOL)resignFirstResponder {
    BOOL r = %orig;
    if (gCurrentInput == self) gCurrentInput = nil;
    return r;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); if (self.isFirstResponder) gCurrentInput = self; }
}

// 捕获输入框真实 delegate 类，hook 其 textView:editMenuForTextRange:suggestedActions:（iOS16 决定菜单内容与顺序）。
- (void)setDelegate:(id)delegate {
    if (gMenuFilterEnabled && delegate && chatmenu_isAppClass([delegate class])) {
        Class dcls = [delegate class];
        NSString *key = NSStringFromClass(dcls);
        if (![gTextMenuHooked containsObject:key]) {
            [gTextMenuHooked addObject:key];
            chatmenu_log([NSString stringWithFormat:@"[tvSetDelegate] %@ isInput=%d", key,
                          ([delegate isKindOfClass:[UITextView class]]||[delegate isKindOfClass:[UITextField class]])?1:0]);
            BOOL defines = NO;
            unsigned int mc = 0;
            Method *ml = class_copyMethodList(dcls, &mc);
            for (unsigned int i = 0; i < mc; i++) {
                if (method_getName(ml[i]) == @selector(textView:editMenuForTextRange:suggestedActions:)) { defines = YES; break; }
            }
            if (ml) free(ml);
            if (defines) {
                Method m = class_getInstanceMethod(dcls, @selector(textView:editMenuForTextRange:suggestedActions:));
                IMP newImp = (IMP)chatmenu_textMenuReplacement;
                IMP origImp = method_setImplementation(m, newImp);
                if (origImp) [gTextMenuOrig setObject:[NSValue valueWithPointer:(void *)origImp] forKey:key];
                chatmenu_log([NSString stringWithFormat:@"[tvEditMenu] hooked %@ orig=%d", key, origImp ? 1 : 0]);
            } else {
                chatmenu_log([NSString stringWithFormat:@"[tvEditMenu] skip not-override %@", key]);
            }
        }
    }
    %orig;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    if (action == gSelSelectAll || action == gSelCopy || action == gSelPaste) return YES;
    if (gInjectingCustom) return NO;
    if (chatmenu_isAllowedAction(action)) return YES;
    return NO;
}

// 兜底：若 delegate 恰为输入框自身（部分 App），此 hook 直接排序。
- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)configuration suggestedActions:(NSArray *)suggestedActions {
    if (!gMenuFilterEnabled) return %orig;
    chatmenu_log([NSString stringWithFormat:@"[emi] self=%@", NSStringFromClass([self class])]);
    id origMenu = %orig;
    return chatmenu_filterAndOrderMenu(origMenu);
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); gCurrentInput = self; }
    return r;
}
- (BOOL)resignFirstResponder {
    BOOL r = %orig;
    if (gCurrentInput == self) gCurrentInput = nil;
    return r;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); if (self.isFirstResponder) gCurrentInput = self; }
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    if ((action == @selector(copy:) || action == @selector(selectAll:)) && self.secureTextEntry) return %orig;
    if (action == gSelSelectAll || action == gSelCopy || action == gSelPaste) return YES;
    if (gInjectingCustom) return NO;
    if (chatmenu_isAllowedAction(action)) return YES;
    return NO;
}

- (id)editMenuInteraction:(id)interaction menuForConfiguration:(id)configuration suggestedActions:(NSArray *)suggestedActions {
    if (!gMenuFilterEnabled) return %orig;
    chatmenu_log([NSString stringWithFormat:@"[emi] self=%@", NSStringFromClass([self class])]);
    id origMenu = %orig;
    return chatmenu_filterAndOrderMenu(origMenu);
}
%end

// ==================== 现代路径 A：UIEditMenuInteraction 的 delegate（系统类也要 hook） ====================
// QQ 实测用 initWithDelegate: 设 delegate（init 时即设，setDelegate: 不一定被调用），故两个入口都捕获。
// 该 delegate 即真正构建编辑菜单的对象，其 editMenuInteraction:menuForConfiguration:suggestedActions:
// 返回 UIMenu（决定内容+顺序）。
// ★ 关键：iOS16 标准文本框编辑菜单的构建者就是 UIKit 系统类
//   _UIContextMenuInteractionBasedTextContextInteraction（delegate 是它，不是文本框、也不是 App 类）。
//   canPerformAction 只管显隐，顺序由这个系统类的方法写死 → 必须 hook 它才能排序/过滤。
//   故不再跳过系统类：用 class_addMethod 在该类上加覆盖（仅影响该类、不污染 UIKit 父类全局 IMP；
//   运行时对新增 IMP 做 PAC 签名，PAC 安全）。%ctor 还会按类名直接 hook 该系统类兜底。
static void chatmenu_hookEditMenuDelegateClass(Class dcls) {
    if (!gMenuFilterEnabled || !dcls) return;
    NSString *key = NSStringFromClass(dcls);
    if ([gEditMenuHooked containsObject:key]) return;
    [gEditMenuHooked addObject:key];
    BOOL isApp = chatmenu_isAppClass(dcls);
    chatmenu_log([NSString stringWithFormat:@"[emiDelegate] seen %@ isApp=%d", key, isApp ? 1 : 0]);
    // 文本框自身由 %hook UITextView/UITextField 处理，避免双重 hook
    if ([dcls isSubclassOfClass:[UITextView class]] ||
        [dcls isSubclassOfClass:[UITextField class]]) {
        return;
    }
    SEL sel = @selector(editMenuInteraction:menuForConfiguration:suggestedActions:);
    Method m = class_getInstanceMethod(dcls, sel);
    if (!m) { chatmenu_log([NSString stringWithFormat:@"[emiDelegate] skip no-method %@", key]); return; }
    IMP newImp = (IMP)chatmenu_editMenuReplacement;
    // 该类自身是否实现该方法？（避免 class_containsMethod 在某些 SDK 未声明，用 class_copyMethodList 判断）
    BOOL ownMethod = NO;
    unsigned int mc = 0;
    Method *mlist = class_copyMethodList(dcls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        if (method_getName(mlist[i]) == sel) { ownMethod = YES; break; }
    }
    if (mlist) free(mlist);
    if (ownMethod) {
        // 类自身实现 → 直接替换 IMP（仅影响该类，安全）
        IMP orig = method_setImplementation(m, newImp);
        if (orig) [gEditMenuOrig setObject:[NSValue valueWithPointer:(void *)orig] forKey:key];
        chatmenu_log([NSString stringWithFormat:@"[emiDelegate] hooked(self) %@ orig=%d", key, orig ? 1 : 0]);
    } else {
        // 继承自父类（UIKit）→ 在该类上 addMethod 覆盖，避免污染父类全局 IMP
        IMP orig = method_getImplementation(m); // 父类（UIKit）实现
        if (class_addMethod(dcls, sel, newImp, method_getTypeEncoding(m))) {
            if (orig) [gEditMenuOrig setObject:[NSValue valueWithPointer:(void *)orig] forKey:key];
            chatmenu_log([NSString stringWithFormat:@"[emiDelegate] hooked(add) %@ orig=%d", key, orig ? 1 : 0]);
        } else {
            chatmenu_log([NSString stringWithFormat:@"[emiDelegate] addMethod-fail %@", key]);
        }
    }
}

static void chatmenu_hookEditMenuDelegateIfNeeded(id delegate) {
    if (!delegate) return;
    chatmenu_hookEditMenuDelegateClass([delegate class]);
}

%hook UIEditMenuInteraction
- (instancetype)initWithDelegate:(id)delegate {
    chatmenu_hookEditMenuDelegateIfNeeded(delegate);
    return %orig;
}
- (void)setDelegate:(id)delegate {
    chatmenu_hookEditMenuDelegateIfNeeded(delegate);
    %orig;
}
%end

// ==================== PATH B：老式 UIMenuController（兼容仍走老 API 的 App） ====================
%hook UIMenuController
- (void)setMenuVisible:(BOOL)visible animated:(BOOL)animated {
    if (visible && gMenuFilterEnabled) {
        UIResponder *fr = gCurrentInput;
        chatmenu_log([NSString stringWithFormat:@"[ucVis] visible=1 fr=%@",
                      fr ? NSStringFromClass([fr class]) : @"NIL"]);
        if (([fr isKindOfClass:[UITextView class]] || [fr isKindOfClass:[UITextField class]]) &&
            !([fr isKindOfClass:[UITextField class]] && ((UITextField *)fr).secureTextEntry)) {
            gInjectingCustom = YES;
            NSMutableArray *items = [NSMutableArray array];
            [items addObject:[[UIMenuItem alloc] initWithTitle:@"全选" action:gSelSelectAll]];
            [items addObject:[[UIMenuItem alloc] initWithTitle:@"复制" action:gSelCopy]];
            [items addObject:[[UIMenuItem alloc] initWithTitle:@"粘贴" action:gSelPaste]];
            [self setMenuItems:items];
            chatmenu_log(@"[legacyMenu] injected 全选/复制/粘贴");
        }
    }
    %orig;
    gInjectingCustom = NO;
}
%end

// ==================== 自定义 action 转发（legacy 路径 UIMenuItem 点击时调用） ====================
%hook UITextView
- (void)chatswipe_selectAll:(id)sender { [self selectAll:sender]; }
- (void)chatswipe_copy:(id)sender      { [self copy:sender]; }
- (void)chatswipe_paste:(id)sender     { [self paste:sender]; }
%end
%hook UITextField
- (void)chatswipe_selectAll:(id)sender { [self selectAll:sender]; }
- (void)chatswipe_copy:(id)sender      { [self copy:sender]; }
- (void)chatswipe_paste:(id)sender     { [self paste:sender]; }
%end

%ctor {
    gSelSelectAll = NSSelectorFromString(@"chatswipe_selectAll:");
    gSelCopy       = NSSelectorFromString(@"chatswipe_copy:");
    gSelPaste      = NSSelectorFromString(@"chatswipe_paste:");
    gEditMenuOrig  = [NSMutableDictionary dictionary];
    gEditMenuHooked = [NSMutableSet set];
    gTextMenuOrig  = [NSMutableDictionary dictionary];
    gTextMenuHooked = [NSMutableSet set];

    chatswipe_loadConfig();
    @try {
        NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
                          stringByAppendingPathComponent:@"chatswipe.log"];
        [@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } @catch (id e) {}
    // 直接 hook iOS16 文本框编辑菜单的标准构建者（UIKit 系统类），兜底不依赖 initWithDelegate 捕获
    Class sysEditCls = NSClassFromString(@"_UIContextMenuInteractionBasedTextContextInteraction");
    if (sysEditCls) chatmenu_hookEditMenuDelegateClass(sysEditCls);
    chatmenu_log([NSString stringWithFormat:@"chatswipe v1.5.8 loaded %@", [NSDate date]]);
}
