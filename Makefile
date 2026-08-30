TARGET := iphone:clang:14.0:14.0
INSTALL_TARGET_PROCESSES = SpringBoard
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SquidToPullOverX

SquidToPullOverX_FILES = SquidToPullOverX.mm
SquidToPullOverX_CFLAGS = -fobjc-arc -fobjc-arc-exceptions
SquidToPullOverX_FRAMEWORKS = UIKit Foundation
SquidToPullOverX_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk