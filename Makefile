# Oback — OPPO 风格边缘手势返回（roothide / iOS 16.4.1）
# 直接用 roothide 官方 theos 分支（roothide/theos）构建：
#   make package FINALPACKAGE=1
# roothide/theos 内置 roothide package scheme，make package 直接产出
# iphoneos-arm64e 的 roothide .deb（路径即 /var/jb 布局），无需 RootHidePatcher/patch.sh。
# 注意：必须用 roothide/theos，标准 theos/theos 没有 roothide scheme。

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := Oback
Oback_FILES := Tweak.xm \
                  ObackManager.m \
                  ObackTransition.m \
                  ObackPreferences.m

Oback_FRAMEWORKS := UIKit
Oback_PRIVATE_FRAMEWORKS :=
Oback_LIBRARIES :=

include $(THEOS_MAKE_PATH)/tweak.mk

# 安装后重新加载 backboardd，让所有 App 重新注入
after-install::
	install.exec "killall -9 backboardd" 2>/dev/null || true
