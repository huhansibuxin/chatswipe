TARGET = iphone:clang:latest:16.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = chatswipe
chatswipe_FILES = Tweak.xm
chatswipe_CFLAGS = -fobjc-arc -w

include $(THEOS_MAKE_PATH)/tweak.mk
