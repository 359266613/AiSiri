DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.5
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AiSiri
AiSiri_FILES = Hooks/AxsAiSiriSessionHooks.xm Sources/AxsAiSiriConfig.m Sources/AxsAiSiriDiagnostics.m Sources/AxsAiSiriProbeManager.m Sources/AxsAiSiriTrigger.m
AiSiri_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I./Headers -I./Sources
AiSiri_CCFLAGS = -std=c++17
AiSiri_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AiSiriprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
