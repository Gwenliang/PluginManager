# QQ Plugin Manager (theos)
# 编译环境：macOS + theos，或直接使用仓库内 GitHub Actions（Linux 亦可编译 arm64e）

export ARCHS = arm64e
export TARGET = iphone:clang:17.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PluginManager
PluginManager_FILES = PluginManager.mm
PluginManager_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
