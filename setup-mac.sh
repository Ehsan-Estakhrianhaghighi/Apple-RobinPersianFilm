#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null; then
  echo "Install XcodeGen with: brew install xcodegen"
  exit 1
fi
xcodegen generate
open RobinPersianFilmApple.xcodeproj
echo "Select RobinPersianFilmTV or RobinPersianFilmIOS, configure signing and Run."
