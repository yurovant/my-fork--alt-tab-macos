#!/usr/bin/env bash

# set to empty for debug builds
OTHER_CODE_SIGN_FLAGS="${OTHER_CODE_SIGN_FLAGS:-}"

set -exu

AUTOUPDATE_APP="${CODESIGNING_FOLDER_PATH}/Contents/Frameworks/Sparkle.framework/Versions/A/Resources/Autoupdate.app"
if [[ ! -e "$AUTOUPDATE_APP" ]]; then
	exit 0
fi

# codesign --deep is only 1 level deep. It misses Sparkle embedded app AutoUpdate
# this build phase script works around the issue

codesign --verbose --force --sign "$CODE_SIGN_IDENTITY" $OTHER_CODE_SIGN_FLAGS "$AUTOUPDATE_APP"
