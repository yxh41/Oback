# Oback — OPPO 风格边缘手势返回（roothide / iOS 16.4.1）
# roothide 没有内置 theos package scheme，官方推荐流程：
#   1) 用 rootless scheme 编出 .deb（/var/jb 布局，架构 iphoneos-arm64）
#   2) 用 roothide 官方的 RootHidePatcher/patch.sh 转成 roothide .deb
#      （把 /var/jb 路径重写进 @loader_path/.jbroot/，架构改为 iphoneos-arm64e）
# 本地出 roothide 包：make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
#                    sudo bash patch.sh packages/xxx_rootless.deb packages/oback_roothide.deb

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

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
