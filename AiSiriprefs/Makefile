ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.5

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AiSiriPrefs
AiSiriPrefs_FILES = AxsRootListController.m ../Sources/AxsConfig.m ../Sources/AxsDiagnostics.m
AiSiriPrefs_CFLAGS = -fobjc-arc -I../Sources
AiSiriPrefs_FRAMEWORKS = Foundation UIKit
AiSiriPrefs_PRIVATE_FRAMEWORKS = Preferences
# Search the patched SDK even when TARGET selects an Xcode SDK.
AiSiriPrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
AiSiriPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
