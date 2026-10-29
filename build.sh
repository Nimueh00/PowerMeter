#!/bin/zsh
# Kullanım: ./build.sh            → sadece derle
#           ./build.sh --install  → derle, /Applications'a kur ve başlat
set -e
cd "$(dirname "$0")"
APP=Panel.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
swiftc -O -wmo -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o $APP/Contents/MacOS/Panel
cp Info.plist $APP/Contents/
codesign --force --sign - $APP
echo "Hazır: $(pwd)/$APP"

if [[ "$1" == "--install" ]]; then
  pkill -x Panel || true
  sleep 0.5
  rm -rf /Applications/Panel.app
  ditto $APP /Applications/Panel.app
  open /Applications/Panel.app
  echo "Kuruldu: /Applications/Panel.app"
fi
