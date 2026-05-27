#!/bin/bash
#
# ============================================================
# 微信防撤回一键 Patch 脚本
# ============================================================
#
# 适用版本: 微信 4.1.9 (CFBundleVersion: 268602)
# 适用平台: macOS (Apple Silicon + Intel)
# 依赖工具: python3, codesign, tar (macOS 系统自带)
#
# 使用方法:
#   chmod +x patch.sh        # 首次使用需添加执行权限
#   ./patch.sh               # 应用防撤回补丁
#   ./patch.sh --restore     # 恢复原始微信（撤销补丁）
#   ./patch.sh --status      # 查看当前补丁状态
#
# 原理:
#   修改 wechat.dylib 中的 isRevokeMessage() 函数，
#   使其始终返回 false，微信将不再识别撤回通知，
#   消息保持可见。不影响自己主动撤回消息。
#
# 注意:
#   - 微信更新后需要重新运行此脚本
#   - 首次运行可能需要约 30 秒（解除系统保护）
#   - 同时 patch arm64 和 x86_64，Apple Silicon 和 Intel Mac 通用
#
# ============================================================

set -e

# ======================== 配置 ========================
WECHAT_APP="/Applications/WeChat.app"
DYLIB_PATH="$WECHAT_APP/Contents/Resources/wechat.dylib"
BACKUP_DIR="$HOME/.wechat_patch_backup"
EXPECTED_VERSION="268602"
EXPECTED_VERSION_STR="4.1.9"

# arm64 patch 参数
ARM64_SLICE_OFFSET="0x9B18000"
ARM64_PATCH_VA="0x44E3D50"
ARM64_PATCH_HEX="00008052C0035FD6"       # MOV W0, #0; RET (8 bytes)
ARM64_ORIGINAL_MASK="9F000000"            # ADRP 指令掩码
ARM64_ORIGINAL_EXPECT="90000000"          # ADRP 指令特征
ARM64_PATCH_LEN=8

# x86_64 patch 参数
X86_SLICE_OFFSET="0x4000"
X86_PATCH_VA="0x4AF08D0"
X86_PATCH_HEX="31C0C3"                   # XOR EAX, EAX; RET (3 bytes)
X86_ORIGINAL_HEX="488B05"                # MOV RAX, [RIP+...] 前3字节
X86_PATCH_LEN=3
# =====================================================

print_banner() {
    echo ""
    echo "=============================="
    echo " 微信防撤回 Patch 工具"
    echo " 适用: macOS / 微信 $EXPECTED_VERSION_STR"
    echo " 支持: Apple Silicon + Intel"
    echo "=============================="
    echo ""
}

print_usage() {
    echo "用法:"
    echo "  $0              应用防撤回补丁"
    echo "  $0 --restore    恢复原始微信"
    echo "  $0 --status     查看补丁状态"
    echo "  $0 --help       显示帮助"
}

# 检查基本环境
check_environment() {
    # 检查 python3
    if ! command -v python3 &>/dev/null; then
        echo "[ERROR] 未找到 python3，请安装 Xcode Command Line Tools:"
        echo "        xcode-select --install"
        exit 1
    fi

    # 检查微信是否存在
    if [ ! -d "$WECHAT_APP" ]; then
        echo "[ERROR] 未找到微信: $WECHAT_APP"
        exit 1
    fi

    # 检查版本
    VERSION=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)
    if [ "$VERSION" != "$EXPECTED_VERSION" ]; then
        echo "[ERROR] 微信版本不匹配"
        echo "        期望: $EXPECTED_VERSION ($EXPECTED_VERSION_STR)"
        echo "        实际: $VERSION"
        echo ""
        echo "        此脚本仅适用于微信 $EXPECTED_VERSION_STR 版本。"
        echo "        请确认你的微信版本，或联系脚本提供者获取对应版本的补丁。"
        exit 1
    fi

    # 检查 wechat.dylib
    if [ ! -f "$DYLIB_PATH" ]; then
        echo "[ERROR] 未找到核心文件: $DYLIB_PATH"
        echo "        微信安装可能不完整，请重新安装微信后再试。"
        exit 1
    fi
}

# 获取当前 patch 状态 (同时检查两个架构)
get_patch_status() {
    python3 -c "
import struct

dylib = '$DYLIB_PATH'
arm64_off = $ARM64_SLICE_OFFSET + $ARM64_PATCH_VA
x86_off = $X86_SLICE_OFFSET + $X86_PATCH_VA

with open(dylib, 'rb') as f:
    # 检查 arm64
    f.seek(arm64_off)
    arm64_bytes = f.read($ARM64_PATCH_LEN)
    arm64_patched = (arm64_bytes == bytes.fromhex('$ARM64_PATCH_HEX'))

    # 检查 x86_64
    f.seek(x86_off)
    x86_bytes = f.read($X86_PATCH_LEN)
    x86_patched = (x86_bytes == bytes.fromhex('$X86_PATCH_HEX'))

if arm64_patched and x86_patched:
    print('patched')
elif not arm64_patched and not x86_patched:
    # 验证是否是原始字节
    insn = struct.unpack_from('<I', arm64_bytes, 0)[0]
    arm64_ok = (insn & 0x$ARM64_ORIGINAL_MASK) == 0x$ARM64_ORIGINAL_EXPECT
    x86_ok = (x86_bytes == bytes.fromhex('$X86_ORIGINAL_HEX'))
    if arm64_ok and x86_ok:
        print('original')
    else:
        print('unknown')
elif arm64_patched or x86_patched:
    print('partial')
else:
    print('unknown')
" 2>/dev/null
}

# 保存原始字节用于恢复
save_original_bytes() {
    mkdir -p "$BACKUP_DIR"
    python3 -c "
dylib = '$DYLIB_PATH'
arm64_off = $ARM64_SLICE_OFFSET + $ARM64_PATCH_VA
x86_off = $X86_SLICE_OFFSET + $X86_PATCH_VA

with open(dylib, 'rb') as f:
    f.seek(arm64_off)
    arm64_orig = f.read($ARM64_PATCH_LEN)
    f.seek(x86_off)
    x86_orig = f.read($X86_PATCH_LEN)

with open('$BACKUP_DIR/arm64.bytes', 'wb') as f:
    f.write(arm64_orig)
with open('$BACKUP_DIR/x86_64.bytes', 'wb') as f:
    f.write(x86_orig)
print('saved')
" 2>/dev/null
}

# 关闭微信
kill_wechat() {
    if pgrep -x WeChat >/dev/null 2>&1; then
        echo "[INFO] 关闭微信..."
        killall WeChat 2>/dev/null || true
        sleep 2
    fi
}

# 解除 provenance 保护
remove_provenance() {
    echo "[INFO] 检测到系统保护，正在解除..."
    echo "[INFO] 重建 WeChat.app 中（约 30 秒）..."

    TMP_DIR=$(mktemp -d)
    tar --no-xattrs -cf - -C /Applications WeChat.app | tar -xf - -C "$TMP_DIR/"
    rm -rf "$WECHAT_APP"
    mv "$TMP_DIR/WeChat.app" "$WECHAT_APP"
    rm -rf "$TMP_DIR"

    echo "[INFO] 系统保护已解除"
}

# 写入 patch 字节 (同时 patch 两个架构)
write_patch() {
    python3 -c "
import struct

dylib = '$DYLIB_PATH'
arm64_off = $ARM64_SLICE_OFFSET + $ARM64_PATCH_VA
x86_off = $X86_SLICE_OFFSET + $X86_PATCH_VA
arm64_patch = bytes.fromhex('$ARM64_PATCH_HEX')
x86_patch = bytes.fromhex('$X86_PATCH_HEX')

try:
    with open(dylib, 'r+b') as f:
        # 验证 arm64 原始字节
        f.seek(arm64_off)
        arm64_orig = f.read(4)
        insn = struct.unpack_from('<I', arm64_orig, 0)[0]
        if (insn & 0x$ARM64_ORIGINAL_MASK) != 0x$ARM64_ORIGINAL_EXPECT:
            # 可能已经 patch 过
            if arm64_orig[:len(arm64_patch)] == arm64_patch[:4]:
                pass  # 已 patch，继续处理 x86
            else:
                print('bad_arm64')
                exit()

        # 验证 x86_64 原始字节
        f.seek(x86_off)
        x86_orig = f.read(3)
        if x86_orig != bytes.fromhex('$X86_ORIGINAL_HEX'):
            if x86_orig == x86_patch:
                pass  # 已 patch
            else:
                print('bad_x86')
                exit()

        # 写入 arm64 patch
        f.seek(arm64_off)
        f.write(arm64_patch)

        # 写入 x86_64 patch
        f.seek(x86_off)
        f.write(x86_patch)

        print('ok')
except PermissionError:
    print('permission_denied')
except Exception as e:
    print(f'error:{e}')
" 2>/dev/null
}

# 恢复原始字节
write_restore() {
    python3 -c "
dylib = '$DYLIB_PATH'
arm64_off = $ARM64_SLICE_OFFSET + $ARM64_PATCH_VA
x86_off = $X86_SLICE_OFFSET + $X86_PATCH_VA

try:
    with open('$BACKUP_DIR/arm64.bytes', 'rb') as f:
        arm64_orig = f.read()
    with open('$BACKUP_DIR/x86_64.bytes', 'rb') as f:
        x86_orig = f.read()

    with open(dylib, 'r+b') as f:
        f.seek(arm64_off)
        f.write(arm64_orig)
        f.seek(x86_off)
        f.write(x86_orig)

    print('ok')
except PermissionError:
    print('permission_denied')
except FileNotFoundError as e:
    print('no_backup')
except Exception as e:
    print(f'error:{e}')
" 2>/dev/null
}

# 重签名
resign_app() {
    echo "[INFO] 重签名..."
    codesign --force --sign - "$DYLIB_PATH" 2>/dev/null
    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
}

# ======================== 主命令: patch ========================
do_patch() {
    print_banner
    check_environment

    echo "[INFO] 微信版本: $EXPECTED_VERSION_STR ($EXPECTED_VERSION)"
    echo "[INFO] 当前架构: $(uname -m)"

    STATUS=$(get_patch_status)
    if [ "$STATUS" = "patched" ]; then
        echo "[INFO] 防撤回补丁已生效，无需重复操作。"
        echo ""
        echo "[DONE] 直接打开微信即可: open /Applications/WeChat.app"
        exit 0
    fi

    kill_wechat

    # 保存原始字节
    save_original_bytes

    # 尝试写入
    echo "[INFO] 正在应用补丁 (arm64 + x86_64)..."
    RESULT=$(write_patch)

    # 如果权限不够，解除保护后重试
    if [ "$RESULT" = "permission_denied" ]; then
        remove_provenance
        RESULT=$(write_patch)
    fi

    if [ "$RESULT" != "ok" ]; then
        echo "[ERROR] 补丁写入失败: $RESULT"
        echo "        请确认微信未在运行，或尝试重新安装微信后再试。"
        exit 1
    fi

    # 重签名
    resign_app

    # 验证
    if [ "$(get_patch_status)" = "patched" ]; then
        echo ""
        echo "=============================="
        echo " 补丁成功！防撤回已生效"
        echo "=============================="
        echo ""
        echo " 打开微信: open /Applications/WeChat.app"
        echo ""
        echo " 恢复原始: $0 --restore"
        echo " 查看状态: $0 --status"
        echo ""
    else
        echo "[ERROR] 补丁验证失败!"
        exit 1
    fi
}

# ======================== 主命令: restore ========================
do_restore() {
    print_banner
    check_environment

    STATUS=$(get_patch_status)
    if [ "$STATUS" = "original" ]; then
        echo "[INFO] 微信未被修改，无需恢复。"
        exit 0
    fi

    if [ ! -f "$BACKUP_DIR/arm64.bytes" ] || [ ! -f "$BACKUP_DIR/x86_64.bytes" ]; then
        echo "[ERROR] 未找到备份文件: $BACKUP_DIR/"
        echo "        无法恢复。建议重新安装微信。"
        exit 1
    fi

    kill_wechat

    echo "[INFO] 正在恢复原始微信..."

    RESULT=$(write_restore)

    if [ "$RESULT" = "permission_denied" ]; then
        remove_provenance
        RESULT=$(write_restore)
    fi

    if [ "$RESULT" != "ok" ]; then
        echo "[ERROR] 恢复失败: $RESULT"
        exit 1
    fi

    resign_app

    echo ""
    echo "=============================="
    echo " 已恢复原始微信"
    echo "=============================="
    echo ""
}

# ======================== 主命令: status ========================
do_status() {
    print_banner
    check_environment

    STATUS=$(get_patch_status)
    echo "[INFO] 微信版本: $EXPECTED_VERSION_STR ($EXPECTED_VERSION)"
    echo "[INFO] 当前架构: $(uname -m)"
    case "$STATUS" in
        patched)
            echo "[INFO] 补丁状态: 已生效 (arm64 + x86_64 均已 patch)"
            ;;
        partial)
            echo "[WARN] 补丁状态: 部分生效 (建议重新运行 $0)"
            ;;
        original)
            echo "[INFO] 补丁状态: 未应用 (原始状态)"
            ;;
        *)
            echo "[WARN] 补丁状态: 未知 (文件可能被其他工具修改)"
            ;;
    esac
    echo ""
}

# ======================== 入口 ========================
case "${1:-}" in
    --restore|-r)
        do_restore
        ;;
    --status|-s)
        do_status
        ;;
    --help|-h)
        print_banner
        print_usage
        ;;
    "")
        do_patch
        ;;
    *)
        echo "[ERROR] 未知参数: $1"
        echo ""
        print_usage
        exit 1
        ;;
esac
