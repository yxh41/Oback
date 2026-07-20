# Oback — OPPO 风格边缘手势返回（roothide / iOS 16.4.1）
# 构建：make package THEOS_PACKAGE_SCHEME=roothide
# 也可直接在下面写死 THEOS_PACKAGE_SCHEME，省得每次带环境变量。

TARGET := iphone:clang:16.4
ARCHS := arm64
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
