# chatswipe — 通用聊天输入框滑动插件 (rootless / ElleKit / NathanLR)
# 编译方式照搬已验证的微信插件 wctweak / WeChatNotifyFix：
# - SDK 用 theos/sdks 的 master.zip 抽 iPhoneOS16.5.sdk 子目录（tar.xz 路径 404 不可用）
# - theos 自动链接 substrate（TrollFools + ElleKit 加载需要）

export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless
export ERROR_ON_WARNINGS = 0
export LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = chatswipe

chatswipe_FILES = Tweak.xm
chatswipe_FRAMEWORKS = UIKit
# 关键：TrollFools + ElleKit 只加载链接了 substrate(=ellekit) 的 dylib，
# 故链接仓库内自带 CydiaSubstrate.framework（见 Frameworks/），与 wctweak 一致。
chatswipe_LDFLAGS = -Wl,-no_warn_inits -F$(THEOS_PROJECT_DIR)/Frameworks -framework CydiaSubstrate
chatswipe_CFLAGS = -fobjc-arc -fno-modules -w

include $(THEOS_MAKE_PATH)/tweak.mk
