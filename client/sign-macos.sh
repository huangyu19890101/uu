#!/usr/bin/env bash
# 在自己的 Mac 上给 homeuu 签名并安装到 /Applications。
#
# 用法：
#   bash sign-macos.sh <homeuu-...-unsigned.dmg 或 homeuu.app> ["签名身份"]
#
# 签名身份用 `security find-identity -v -p codesigning` 查看，形如
#   "Apple Development: you@example.com (ABCDE12345)"
# 只有一个身份时可以省略。
#
# 每次升级都必须用同一个签名身份，macOS 才会保留屏幕录制、辅助功能等权限。
set -euo pipefail

APP_NAME="homeuu"
src="${1:?用法：bash sign-macos.sh <dmg 或 app> [签名身份]}"
identity="${2:-}"

die() { echo "错误：$*" >&2; exit 1; }
[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上运行"

if [ -z "$identity" ]; then
    ids="$(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')"
    count="$(printf '%s\n' "$ids" | grep -c . || true)"
    [ "$count" -eq 1 ] || die "找到 $count 个签名身份，请在第二个参数指定：
$ids"
    identity="$ids"
fi
echo "签名身份：$identity"

work="$(mktemp -d)"
mnt=""
cleanup() {
    [ -n "$mnt" ] && hdiutil detach "$mnt" -quiet || true
    rm -rf "$work"
}
trap cleanup EXIT

case "$src" in
    *.dmg)
        mnt="$work/mnt"; mkdir "$mnt"
        hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$src" -quiet
        ditto "$mnt/$APP_NAME.app" "$work/$APP_NAME.app"
        hdiutil detach "$mnt" -quiet; mnt="" ;;
    *.app)
        ditto "$src" "$work/$APP_NAME.app" ;;
    *) die "只支持 .dmg 或 .app" ;;
esac
app="$work/$APP_NAME.app"
[ -x "$app/Contents/MacOS/$APP_NAME" ] || die "$app 里没有 $APP_NAME 主程序"

# 浏览器下载的文件带隔离标记，自己签名的应用不经过 Apple 公证，需去掉标记才能打开
xattr -cr "$app"

# 与上游 Release.entitlements 一致
cat > "$work/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF

# 签名顺序与上游 sign-macos-app.sh 相同：先里后外。所有代码用同一身份签名，
# 开启 hardened runtime 后库验证要求动态库与主程序属于同一个 Team ID。
sign=(codesign --force --options runtime --timestamp=none --sign "$identity")
if [ -d "$app/Contents/Frameworks" ]; then
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then "${sign[@]}" "$f"; fi
    done < <(find "$app/Contents/Frameworks" -type f -print0)
    while IFS= read -r -d '' fw; do
        "${sign[@]}" "$fw"
    done < <(find "$app/Contents/Frameworks" -depth -type d -name '*.framework' -print0)
fi
[ -f "$app/Contents/MacOS/service" ] && "${sign[@]}" "$app/Contents/MacOS/service"
"${sign[@]}" --generate-entitlement-der --entitlements "$work/entitlements.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
echo "Team ID：${team:-无}"
[ -n "$team" ] && [ "$team" != "not set" ] || echo "警告：签名身份没有 Team ID，hardened runtime 下动态库可能加载失败"

dest="/Applications/$APP_NAME.app"
if [ -d "$dest" ]; then
    echo "将替换已安装的 $dest（会先退出正在运行的 $APP_NAME）"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sudo rm -rf "$dest"
fi
sudo ditto "$app" "$dest"
echo "已安装到 $dest"
echo "首次使用：打开 $APP_NAME，按提示授予屏幕录制、辅助功能权限，并在设置里点\"安装\"服务（无人值守需要）。"
