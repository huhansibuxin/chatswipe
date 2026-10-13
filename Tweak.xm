// KbDock — 键盘底部快捷条（全选 / 复制 / 粘贴）
// 分支：键盘注入  |  基于 MyDock(com.ban.mydock) 作者 1.0 源码改造
// 改动：① 删除「撤销」「收起键盘」 ② 新增「复制」 ③ 图标改为自绘虚线（UIBezierPath，无 SF Symbols）
//       ④ 图标颜色用 labelColor → 自动自适应系统深浅色
// Hook: UIKeyboardDockView -layoutSubviews（与原作者一致）
// 交付：单 dylib，经 TrollFools 注入目标进程

#import <UIKit/UIKit.h>

@interface UIKeyboardDockView : UIView
@end

// ==================== 自绘虚线图标 ====================
// kind: 0=全选 1=复制 2=粘贴
static UIImage *KbDashedIcon(NSInteger kind) {
    const CGFloat side = 28.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];

    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setStroke];
        CGFloat dash[2] = {4.0, 5.0};

        void (^prep)(UIBezierPath *) = ^(UIBezierPath *p) {
            p.lineWidth = 1.3;
            p.lineCapStyle = kCGLineCapRound;
            p.lineJoinStyle = kCGLineJoinRound;
            [p setLineDash:dash count:2 phase:0];
        };

        if (kind == 0) {
            // 全选：虚线圆角方框
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, 24, 24) cornerRadius:6];
            prep(p); [p stroke];
        } else if (kind == 1) {
            // 复制：前后两层虚线圆角方框
            UIBezierPath *back  = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(1, 1, 17, 17) cornerRadius:5];
            UIBezierPath *front = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(10, 10, 17, 17) cornerRadius:5];
            prep(back);  [back stroke];
            prep(front); [front stroke];
        } else {
            // 粘贴：虚线剪贴板（板 + 顶部小夹）
            UIBezierPath *board = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(5, 4, 18, 21) cornerRadius:4];
            UIBezierPath *tab   = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(10, 1.5, 8, 5) cornerRadius:1.5];
            prep(board); [board stroke];
            prep(tab);   [tab stroke];
        }
    }];

    // 模板图 + tintColor=labelColor → 自适应深浅色
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// ==================== 按钮 ====================
static UIButton *KbMakeButton(UIImage *icon, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:icon forState:UIControlStateNormal];
    b.tintColor = [UIColor labelColor];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor  constraintEqualToConstant:36].active = YES;
    [b.heightAnchor constraintEqualToConstant:36].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    // 只加一次
    if ([self viewWithTag:9999]) return;

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.tag = 9999;
    stackView.axis = UILayoutConstraintAxisHorizontal;
    stackView.distribution = UIStackViewDistributionEqualSpacing;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;

    [stackView addArrangedSubview:KbMakeButton(KbDashedIcon(0), self, @selector(kb_selectAll))];
    [stackView addArrangedSubview:KbMakeButton(KbDashedIcon(1), self, @selector(kb_copy))];
    [stackView addArrangedSubview:KbMakeButton(KbDashedIcon(2), self, @selector(kb_paste))];

    [self addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stackView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor constant:-23],
        [stackView.widthAnchor    constraintEqualToAnchor:self.widthAnchor multiplier:0.55],
    ]];
}

%new
- (void)kb_haptic {
    UIImpactFeedbackGenerator *g =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g prepare];
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
