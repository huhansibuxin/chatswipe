// KbDock — 键盘底部快捷条（全选 / 复制 / 粘贴）
// 基于 MyDock(com.ban.mydock) 作者 1.0 源码改造：
//   ① 删除「撤销」「收起键盘」 ② 新增「复制」 ③ 自绘「点状」图标（每图标 2 个极小点，靠摆放方向区分）
//   ④ tintColor=labelColor → 自适应系统深浅色
// Hook: UIKeyboardDockView -layoutSubviews
// 交付：单 dylib，经 TrollFools 注入目标进程。

#import <UIKit/UIKit.h>

@interface UIKeyboardDockView : UIView
- (void)kb_haptic;
- (void)kb_selectAll;
- (void)kb_copy;
- (void)kb_paste;
@end

// ---- 自绘点状图标 ----
// 三个图标都只用 2 个点，靠「摆放方向」区分；点径 ≈ 虚线的一个点（1.5pt）
// 画布 26x26，两点居中对称摆放
static CGFloat const kDotD   = 1.5;   // 点直径（极小）
static CGFloat const kDotGap = 5.5;   // 两点中心间距

// kind: 0=一上一下  1=左高右低(左上+右下)  2=左低右高(右上+左下)
static UIImage *KbDotsIcon(NSInteger kind) {
    static UIImage *cache[3] = {nil, nil, nil};   // 性能：三种图标各只渲染一次，键盘复用时不再重绘
    if (kind >= 0 && kind < 3 && cache[kind]) return cache[kind];

    const CGFloat side = 26.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];

    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setFill];

        CGFloat c = side / 2.0;
        CGFloat h = kDotGap / 2.0;
        CGPoint p1, p2;
        if (kind == 0) {          // 一上一下
            p1 = CGPointMake(c, c - h);         p2 = CGPointMake(c, c + h);
        } else if (kind == 1) {   // 左高右低：左上 + 右下
            p1 = CGPointMake(c - h, c - h);     p2 = CGPointMake(c + h, c + h);
        } else {                  // 左低右高：右上 + 左下
            p1 = CGPointMake(c + h, c - h);     p2 = CGPointMake(c - h, c + h);
        }

        UIBezierPath *dot1 = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(p1.x - kDotD / 2.0, p1.y - kDotD / 2.0, kDotD, kDotD)];
        UIBezierPath *dot2 = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(p2.x - kDotD / 2.0, p2.y - kDotD / 2.0, kDotD, kDotD)];
        [dot1 fill];
        [dot2 fill];
    }];

    UIImage *out = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (kind >= 0 && kind < 3) cache[kind] = out;   // 存入缓存
    return out;
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

    // 按钮位置/功能不变（左→右 = 全选 / 复制 / 粘贴）；只调「点」的摆放：
    //   全选 = 左低右高(2) · 复制 = 一上一下(0) · 粘贴 = 左高右低(1) → 视觉呈 / | \ 对称
    [stackView addArrangedSubview:KbMakeButton(KbDotsIcon(2), self, @selector(kb_selectAll))]; // 左低右高
    [stackView addArrangedSubview:KbMakeButton(KbDotsIcon(0), self, @selector(kb_copy))];      // 一上一下
    [stackView addArrangedSubview:KbMakeButton(KbDotsIcon(1), self, @selector(kb_paste))];     // 左高右低

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
