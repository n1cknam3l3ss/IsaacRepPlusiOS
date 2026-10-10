SHELL := /bin/zsh

PROJECT_ROOT := $(CURDIR)
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANGXX := $(shell xcrun --sdk iphoneos --find clang++)
MIN_IOS ?= 15.0
EXTRA_CFLAGS ?=

DYLIB := $(PROJECT_ROOT)/build/IsaacRepPlusiOS.dylib
DEB_STAGE := $(PROJECT_ROOT)/package/stage
DEB := $(PROJECT_ROOT)/packages/IsaacRepPlusiOS-rootless.deb
LIVECONTAINER_FRAMEWORK := $(PROJECT_ROOT)/build/IsaacRepPlusiOS.framework
LIVECONTAINER_ZIP := $(PROJECT_ROOT)/packages/IsaacRepPlusiOS-LiveContainer.framework.zip
DIST := $(PROJECT_ROOT)/dist
RELEASE_ZIP := $(DIST)/IsaacRepPlusiOS.zip

SOURCES := \
	$(PROJECT_ROOT)/src/RepPlusBootstrap.mm \
	$(PROJECT_ROOT)/src/RepPlusLogger.mm \
	$(PROJECT_ROOT)/src/RepPlusVoidPatch.mm

.PHONY: all dylib package livecontainer dist clean

all: dylib package livecontainer dist

dylib:
	mkdir -p "$(PROJECT_ROOT)/build"
	"$(CLANGXX)" -isysroot "$(SDK)" -arch arm64 -miphoneos-version-min="$(MIN_IOS)" \
		-std=c++17 -fobjc-arc -fmodules -O2 $(EXTRA_CFLAGS) -dynamiclib -I"$(PROJECT_ROOT)/include" \
		-Wl,-install_name,@rpath/$(notdir $(DYLIB)) -Wl,-dead_strip \
		-Wl,-exported_symbols_list,"$(PROJECT_ROOT)/package/exports.txt" \
		$(SOURCES) -framework Foundation -framework UIKit -lc++ -o "$(DYLIB)"
	xcrun strip -x "$(DYLIB)"
	@if command -v codesign >/dev/null 2>&1; then codesign --force --sign - --timestamp=none "$(DYLIB)"; elif command -v ldid >/dev/null 2>&1; then ldid -S "$(DYLIB)"; fi

package: dylib
	rm -rf "$(DEB_STAGE)"
	mkdir -p "$(DEB_STAGE)/DEBIAN" "$(DEB_STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries"
	cp "$(PROJECT_ROOT)/package/control" "$(DEB_STAGE)/DEBIAN/control"
	cp "$(PROJECT_ROOT)/package/IsaacRepPlusiOS.plist" "$(DEB_STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/IsaacRepPlusiOS.plist"
	cp "$(DYLIB)" "$(DEB_STAGE)/var/jb/Library/MobileSubstrate/DynamicLibraries/IsaacRepPlusiOS.dylib"
	mkdir -p "$(PROJECT_ROOT)/packages"
	dpkg-deb --root-owner-group --build "$(DEB_STAGE)" "$(DEB)"

livecontainer: dylib
	rm -rf "$(LIVECONTAINER_FRAMEWORK)"
	mkdir -p "$(LIVECONTAINER_FRAMEWORK)"
	cp "$(DYLIB)" "$(LIVECONTAINER_FRAMEWORK)/IsaacRepPlusiOS"
	cp "$(PROJECT_ROOT)/livecontainer/Info.plist" "$(LIVECONTAINER_FRAMEWORK)/Info.plist"
	chmod 755 "$(LIVECONTAINER_FRAMEWORK)/IsaacRepPlusiOS"
	mkdir -p "$(PROJECT_ROOT)/packages"
	rm -f "$(LIVECONTAINER_ZIP)"
	/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$(LIVECONTAINER_FRAMEWORK)" "$(LIVECONTAINER_ZIP)"

dist: package livecontainer
	mkdir -p "$(DIST)"
	cp "$(DYLIB)" "$(DIST)/"
	cp "$(DEB)" "$(DIST)/"
	cp "$(LIVECONTAINER_ZIP)" "$(DIST)/"
	cd "$(DIST)" && zip -r "$(RELEASE_ZIP)" IsaacRepPlusiOS.dylib "$(notdir $(DEB))" "$(notdir $(LIVECONTAINER_ZIP))"

clean:
	rm -rf "$(PROJECT_ROOT)/build" "$(PROJECT_ROOT)/packages" "$(PROJECT_ROOT)/dist" "$(DEB_STAGE)"
