# Browser Notes — quick note capture from the browser.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. SPM project, embedded Sparkle,
# dual-ship (.zip + .pkg).

BUNDLE_NAME      := BrowserNotes
BUNDLE_TYPE      := app
PRODUCT_NAME     := BrowserNotes.app
BUNDLE_ID        := cc.jorviksoftware.BrowserNotes
BUILD_SYSTEM     := spm
SPM_PRODUCT      := BrowserNotes

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := BrowserNotes.entitlements

include ../jorvik-release/release.mk
