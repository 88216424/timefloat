#!/usr/bin/env bash
# =============================================================================
#  三源对时 · iOS 一键打包 .ipa（必须在 macOS 上跑）
#
#  用法：
#    bash tools/build-ipa.sh                    # 打「未签名」.ipa（给 AltStore / Sideloadly + 你的 Apple ID 签）
#    BUNDLE_ID=com.你的名字.timefloat bash tools/build-ipa.sh   # 换包名，避免和已装的 app 冲突
#    DEVELOPMENT_TEAM=ABCDE12345 bash tools/build-ipa.sh        # 有开发者证书就直接打「已签名」.ipa
#
#  产物：dist/TimeFloat-unsigned.ipa  或  dist/TimeFloat.ipa
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/ios"
OUT_DIR="$ROOT/dist"
BUILD_DIR="$IOS_DIR/build"
ARCHIVE="$BUILD_DIR/TimeFloat.xcarchive"
SCHEME="TimeFloat"
PROJECT="$IOS_DIR/TimeFloat.xcodeproj"
TEAM="${DEVELOPMENT_TEAM:-}"
# 免费 Apple ID 签名时，包名建议改成你自己的，免得和已经装过的 app 撞
BUNDLE_ID="${BUNDLE_ID:-com.yesha.timefloat}"

mkdir -p "$OUT_DIR" "$BUILD_DIR"

echo "==> 1/5 检查工具链"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "✗ 没找到 xcodebuild。装 Xcode 后执行： sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
echo "    Xcode: $(xcodebuild -version | head -1)"
echo "    Bundle ID: $BUNDLE_ID"

if [ ! -d "$PROJECT" ]; then
  echo "==> 2/5 生成 Xcode 工程（XcodeGen）"
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "    没装 xcodegen，正在装：brew install xcodegen"
    brew install xcodegen
  fi
  (cd "$IOS_DIR" && xcodegen generate)
else
  echo "==> 2/5 已有工程，跳过生成（要重新生成就先删掉 ios/TimeFloat.xcodeproj）"
fi

echo "==> 3/5 编译并归档（Release / iphoneos）"
rm -rf "$ARCHIVE"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  archive | tail -5

if [ -n "$TEAM" ]; then
  echo "==> 4/5 用证书导出已签名 .ipa（TEAM=$TEAM）"
  EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
  cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>development</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>compileBitcode</key><false/>
    <key>stripSwiftSymbols</key><true/>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
  rm -rf "$BUILD_DIR/export"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$BUILD_DIR/export" \
    -allowProvisioningUpdates | tail -5
  IPA="$(find "$BUILD_DIR/export" -name '*.ipa' | head -1)"
  cp "$IPA" "$OUT_DIR/TimeFloat.ipa"
  echo "==> 5/5 完成"
  echo "    $OUT_DIR/TimeFloat.ipa"
else
  echo "==> 4/5 打包未签名 .ipa（Payload 结构，给 AltStore / Sideloadly 用）"
  APP="$ARCHIVE/Products/Applications/$SCHEME.app"
  [ -d "$APP" ] || { echo "✗ 归档里没找到 $SCHEME.app"; exit 1; }
  rm -rf "$BUILD_DIR/Payload"
  mkdir -p "$BUILD_DIR/Payload"
  cp -R "$APP" "$BUILD_DIR/Payload/"
  (cd "$BUILD_DIR" && rm -f TimeFloat-unsigned.ipa && zip -qr TimeFloat-unsigned.ipa Payload)
  cp "$BUILD_DIR/TimeFloat-unsigned.ipa" "$OUT_DIR/TimeFloat-unsigned.ipa"
  echo "==> 5/5 完成"
  echo "    $OUT_DIR/TimeFloat-unsigned.ipa"
  echo ""
  echo "下一步（用你自己的 Apple ID 签名安装）："
  echo "  1) 电脑装 AltStore(AltServer) 或 Sideloadly，手机用数据线连电脑"
  echo "  2) 把上面这个 ipa 拖进工具里，填你的 Apple ID（免费账号即可）"
  echo "  3) 免费账号有效期 7 天，过期重新签一次；AltStore 可在同一 WiFi 下自动续签"
  echo "  4) 免费账号同时最多 3 个自签 app，包名冲突时换 BUNDLE_ID 重打"
fi

echo ""
echo "产物信息："
ls -lh "$OUT_DIR" | grep -i ipa || true
