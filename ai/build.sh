#!/bin/bash

xcodebuild \
  -workspace alt-tab-macos.xcworkspace \
  -scheme Debug \
  -configuration Debug \
  -derivedDataPath ~/Downloads/Apple_Projects/my-fork--alt-tab-macos
