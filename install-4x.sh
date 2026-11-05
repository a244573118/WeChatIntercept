#!/bin/bash
# 微信防撤回一键安装（4.x 专用）：自动备份原版主程序 + 调用 patch.sh 安装
#
# 用法：
#   ./install-4x.sh              安装（含备份）
#   ./install-4x.sh --no-backup  跳过备份直接安装
#   ./install-4x.sh --help       查看帮助
#
# 注意：旧的 Install.sh 是微信 3.x 系列的安装器，与本脚本无关。
# 其余子命令（--uninstall / --debug / --monitor-*）请直接用 ./patch.sh

set -e
cd "$(dirname "$0")"

WEIXIN_APP="/Applications/WeChat.app"
WEIXIN_BIN="$WEIXIN_APP/Contents/MacOS/WeChat"
DO_BACKUP=1

for arg in "$@"; do
    case "$arg" in
        --no-backup) DO_BACKUP=0 ;;
        --help|-h)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[ERROR] 未知参数: $arg"
            echo "        安装请直接运行 ./install-4x.sh"
            echo "        其他子命令请用 ./patch.sh --uninstall / --debug / --monitor-*"
            exit 1
            ;;
    esac
done

if [ ! -d "$WEIXIN_APP" ]; then
    echo "[ERROR] 未找到微信: $WEIXIN_APP"
    exit 1
fi

VER=$(defaults read "$WEIXIN_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
BUILD=$(defaults read "$WEIXIN_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)
BACKUP="$HOME/wechat_backup_${VER}"

echo "=============================="
echo " 微信防撤回一键安装"
echo " 微信版本: $VER ($BUILD)"
echo "=============================="
echo

# ── 1. 备份原版主程序 ──────────────────────────────
# 微信升级会替换整个 App，旧版本的备份对新版本无效。
# 备份文件名带版本号，避免升级后误用旧备份回滚导致版本错乱。
if [ "$DO_BACKUP" -eq 1 ]; then
    if [ -f "$BACKUP" ]; then
        echo "[1/2] 备份已存在，跳过: $BACKUP"
    else
        echo "[1/2] 备份原版主程序 -> $BACKUP"
        if ! sudo cp "$WEIXIN_BIN" "$BACKUP"; then
            echo "[ERROR] 备份失败，中止（避免无备份状态下修改 App）"
            exit 1
        fi
        sudo chown "$(whoami):$(id -gn)" "$BACKUP" 2>/dev/null || true

        ORIG_SIZE=$(stat -f%z "$WEIXIN_BIN")
        BAK_SIZE=$(stat -f%z "$BACKUP")
        if [ "$ORIG_SIZE" != "$BAK_SIZE" ]; then
            echo "[ERROR] 备份大小不一致 ($BAK_SIZE != $ORIG_SIZE)，中止"
            exit 1
        fi
        if otool -L "$BACKUP" 2>/dev/null | grep -q WeChatAntiRevoke; then
            echo "[WARN] 备份中已含旧的 dylib 引用，建议先 ./patch.sh --uninstall 再重新备份"
        fi
        echo "      sha256: $(shasum -a 256 "$BACKUP" | cut -d' ' -f1)"
    fi
    echo
else
    echo "[1/2] 已跳过备份 (--no-backup)"
    echo
fi

# ── 2. 安装 ───────────────────────────────────────
echo "[2/2] 安装防撤回..."
./patch.sh

echo ""
echo "=============================="
echo " 完成"
echo "=============================="
echo ""
echo " 请手动打开微信（脚本不会自动重启）"
echo ""
echo " 查看日志: tail -f /tmp/antirevoke_debug.log"
echo " 卸载:     ./patch.sh --uninstall"
if [ "$DO_BACKUP" -eq 1 ]; then
echo " 回滚备份: $BACKUP"
fi
echo ""
