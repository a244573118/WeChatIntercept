#!/bin/bash
# 紧急回滚：把微信恢复到未修改状态
#
# 与 ./patch.sh --uninstall 的区别：
#   - patch.sh --uninstall 是从 Mach-O 里移除 LC_LOAD_DYLIB（推荐）
#   - 本脚本用备份整包覆盖主程序，适合 patch.sh --uninstall 失败时兜底
#
# 用法：
#   sudo ./restore.sh
#
# 需要先备份过：~/wechat_backup_<微信版本>

set -e

APP="/Applications/WeChat.app"
BIN="$APP/Contents/MacOS/WeChat"
RES="$APP/Contents/Resources"
DYLIB="$RES/WeChatAntiRevoke.dylib"

VER=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
BACKUP="$HOME/wechat_backup_${VER}"

echo "=============================="
echo " 微信防撤回 - 紧急回滚"
echo " 微信版本: $VER"
echo "=============================="
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 需要 root 权限，请用 sudo 运行"
    exit 1
fi

# ── 1. 退出微信 ─────────────────────────────────
echo "[1/5] 退出微信..."
osascript -e 'quit app "WeChat"' 2>/dev/null || true
pkill -x WeChat 2>/dev/null || true
sleep 2
pkill -9 -x WeChat 2>/dev/null || true

# ── 2. 删除 hook dylib ──────────────────────────
echo "[2/5] 移除 hook dylib..."
rm -f "$DYLIB"
# 清理可能残留的临时构建文件
rm -f "$RES"/WeChatAntiRevoke.*.dylib 2>/dev/null || true

# ── 3. 还原主程序 ───────────────────────────────
echo "[3/5] 还原主程序..."
if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$BIN"
    chmod 755 "$BIN"
    echo "      已从备份还原: $BACKUP"
else
    echo "      [WARN] 未找到备份 $BACKUP"
    echo "      [WARN] 主程序仍含 dylib 引用，微信可能无法启动"
    echo "      [WARN] 请改用 ./patch.sh --uninstall（会移除 LC_LOAD_DYLIB）"
fi

# ── 4. 清除扩展属性 ─────────────────────────────
echo "[4/5] 清除 xattr..."
xattr -cr "$APP" 2>/dev/null || true

# ── 5. 重签名 ───────────────────────────────────
echo "[5/5] 重签名..."
codesign --force --deep --sign - "$APP"

# ── 验证 ────────────────────────────────────────
echo
echo "=============================="
echo " 验证"
echo "=============================="
INJ=$(otool -L "$BIN" 2>/dev/null | grep -c WeChatAntiRevoke || true)
echo " 注入条数（应为 0）:     $INJ"
[ -f "$DYLIB" ] && echo " hook 文件（应为 no）:   yes ⚠️" || echo " hook 文件（应为 no）:   no ✅"
codesign -v "$APP" 2>&1 | head -1 || true

echo
if [ "$INJ" = "0" ] && [ ! -f "$DYLIB" ]; then
    echo "✅ 回滚完成，可重新打开微信"
else
    echo "⚠️ 仍有残留，建议重装微信"
fi
