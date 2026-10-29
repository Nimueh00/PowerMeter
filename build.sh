#!/bin/zsh
# Kullanım: ./build.sh            → sadece derle
#           ./build.sh --install  → derle, /Applications'a kur ve başlat
#           ./build.sh --zip      → derle ve dağıtım için PowerMeter.zip oluştur
set -e
cd "$(dirname "$0")"
NAME=PowerMeter
APP=$NAME.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
swiftc -O -wmo -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  Sources/*.swift -o $APP/Contents/MacOS/$NAME
cp Info.plist $APP/Contents/
codesign --force --sign - $APP
echo "Hazır: $(pwd)/$APP"

if [[ "$1" == "--install" ]]; then
  pkill -x $NAME || true
  sleep 0.5
  rm -rf /Applications/$APP
  ditto $APP /Applications/$APP
  open /Applications/$APP
  echo "Kuruldu: /Applications/$APP"
fi

if [[ "$1" == "--zip" ]]; then
  # ditto imzayı ve paket yapısını bozmadan sıkıştırır
  rm -f $NAME.zip
  ditto -c -k --keepParent $APP $NAME.zip
  echo "Zip: $(pwd)/$NAME.zip"
fi
