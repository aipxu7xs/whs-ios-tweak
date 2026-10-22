# iOS dylib tweak Makefile
# 用法：make SDK=/path/to/iPhoneOS.sdk
# 需要：clang + iOS SDK（Xcode 自带，或从 Theos/llvm 取）
# 产物：tweak.dylib —— 用 insert_dylib 注入自签名 IPA，或随 deb 安装

SDK  ?= /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
ARCH ?= arm64
CC   ?= clang

CFLAGS = -fobjc-arc -dynamiclib -arch $(ARCH) \
         -isysroot $(SDK) -miphoneos-version-min=15.0 \
         -framework Foundation -framework UIKit \
         -framework Photos -framework AVFoundation -framework ImageIO \
         -fvisibility=hidden -O2

tweak.dylib: tweak.m
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f tweak.dylib

.PHONY: clean
