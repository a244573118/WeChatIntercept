#!/bin/bash
#
# ============================================================
# 微信防撤回一键安装脚本
# ============================================================
#
# 适用版本: 微信 4.1.9 (CFBundleVersion: 268602)
# 适用平台: macOS (Apple Silicon + Intel)
# 依赖工具: clang, codesign, python3 (macOS 系统自带)
#
# 使用方法:
#   chmod +x install.sh
#   ./install.sh            # 安装防撤回
#   ./install.sh --uninstall # 卸载（恢复原始微信）
#
# 原理:
#   通过 DYLD 注入一个运行时 hook 动态库，
#   拦截微信的 isRevokeMessage() 函数，
#   区分对方撤回和自己撤回：
#   - 对方撤回 → 返回 false（消息保留不被删除）
#   - 自己撤回 → 返回 true（正常处理，不会闪退）
#
# ============================================================

set -e

WECHAT_APP="/Applications/WeChat.app"
WECHAT_BIN="$WECHAT_APP/Contents/MacOS/WeChat"
DYLIB_DST="$WECHAT_APP/Contents/Resources/WeChatAntiRevoke.dylib"
DYLIB_INSTALL_NAME="@executable_path/../Resources/WeChatAntiRevoke.dylib"
EXPECTED_VERSION="268602"

print_banner() {
    echo ""
    echo "=============================="
    echo " 微信防撤回安装工具"
    echo " 适用: macOS / 微信 4.1.9"
    echo " 支持: Apple Silicon + Intel"
    echo "=============================="
    echo ""
}

check_environment() {
    if [ ! -d "$WECHAT_APP" ]; then
        echo "[ERROR] 未找到微信: $WECHAT_APP"
        exit 1
    fi

    VERSION=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)
    if [ "$VERSION" != "$EXPECTED_VERSION" ]; then
        echo "[ERROR] 微信版本不匹配 (期望 $EXPECTED_VERSION, 实际 $VERSION)"
        exit 1
    fi

    if ! command -v clang &>/dev/null; then
        echo "[ERROR] 未找到 clang，请安装 Xcode Command Line Tools:"
        echo "        xcode-select --install"
        exit 1
    fi
}

kill_wechat() {
    if pgrep -x WeChat >/dev/null 2>&1; then
        echo "[INFO] 关闭微信..."
        killall WeChat 2>/dev/null || true
        sleep 2
    fi
}

remove_provenance() {
    echo "[INFO] 解除系统文件保护（约 30 秒）..."
    TMP_DIR=$(mktemp -d)
    tar --no-xattrs -cf - -C /Applications WeChat.app | tar -xf - -C "$TMP_DIR/"
    rm -rf "$WECHAT_APP"
    mv "$TMP_DIR/WeChat.app" "$WECHAT_APP"
    rm -rf "$TMP_DIR"
    echo "[INFO] 保护已解除"
}

compile_dylib() {
    echo "[INFO] 编译 hook 动态库..."

    # 内嵌 hook.m 源码
    local SRC_FILE=$(mktemp /tmp/hook_XXXXXX.m)
    cat > "$SRC_FILE" << 'HOOK_SOURCE'
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <stdint.h>

static const uintptr_t kSlotVA = 0x9301838;
static const char *kDylibSuffix = "Resources/wechat.dylib";
static const int kMsgTypeOffset = 0x0C;
static const int kRevokeType = 0x2712;

static _Bool hook_isRevokeMessage(void *msg) {
    if (msg == NULL) return 0;
    int32_t msgType = *(int32_t *)((uint8_t *)msg + kMsgTypeOffset);
    if (msgType != kRevokeType) return 0;
    uint32_t field18 = *(uint32_t *)((uint8_t *)msg + 0x18);
    if (field18 == 0x64697877) return 0; // "wxid" = 对方撤回 → 阻止
    return 1; // 自己撤回 → 放行
}

static uintptr_t find_wechat_slide(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL) continue;
        size_t len = strlen(name);
        size_t suffixLen = strlen(kDylibSuffix);
        if (len >= suffixLen && strcmp(name + len - suffixLen, kDylibSuffix) == 0)
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
    }
    return 0;
}

__attribute__((constructor))
static void hook_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        uintptr_t slide = find_wechat_slide();
        if (slide == 0) return;
        void **slot = (void **)(slide + kSlotVA);
        uintptr_t page = (uintptr_t)slot & ~0x3FFF;
        vm_protect(mach_task_self(), (vm_address_t)page, 0x4000, 0, VM_PROT_READ | VM_PROT_WRITE);
        *slot = (void *)&hook_isRevokeMessage;
    });
}
HOOK_SOURCE

    clang -arch arm64 -arch x86_64 -shared -framework Foundation \
        -o "$DYLIB_DST" \
        -install_name "$DYLIB_INSTALL_NAME" \
        "$SRC_FILE" 2>&1

    rm -f "$SRC_FILE"

    if [ ! -f "$DYLIB_DST" ]; then
        echo "[ERROR] 编译失败"
        exit 1
    fi
    echo "[INFO] 编译成功"
}

inject_dylib() {
    echo "[INFO] 注入动态库到微信..."

    python3 << 'INJECT_SCRIPT'
import struct

wechat_path = '/Applications/WeChat.app/Contents/MacOS/WeChat'
dylib_name = b'@executable_path/../Resources/WeChatAntiRevoke.dylib\x00'
while len(dylib_name) % 4 != 0:
    dylib_name += b'\x00'

cmd_size = 24 + len(dylib_name)
while cmd_size % 4 != 0:
    cmd_size += 1
    dylib_name += b'\x00'

with open(wechat_path, 'r+b') as f:
    fat_magic = struct.unpack('>I', f.read(4))[0]
    assert fat_magic == 0xCAFEBABE
    narch = struct.unpack('>I', f.read(4))[0]

    slices = []
    for i in range(narch):
        cpu = struct.unpack('>I', f.read(4))[0]
        sub = struct.unpack('>I', f.read(4))[0]
        offset = struct.unpack('>I', f.read(4))[0]
        size = struct.unpack('>I', f.read(4))[0]
        align = struct.unpack('>I', f.read(4))[0]
        slices.append((cpu, offset, size))

    for cpu, slice_offset, size in slices:
        f.seek(slice_offset)
        magic = struct.unpack('<I', f.read(4))[0]
        if magic != 0xFEEDFACF:
            continue
        f.read(12)
        ncmds_pos = f.tell()
        ncmds = struct.unpack('<I', f.read(4))[0]
        sizeofcmds_pos = f.tell()
        sizeofcmds = struct.unpack('<I', f.read(4))[0]
        f.read(8)

        # Check if already injected
        header_end = slice_offset + 32
        f.seek(header_end)
        already = False
        for i in range(ncmds):
            pos = f.tell()
            cmd = struct.unpack('<I', f.read(4))[0]
            cs = struct.unpack('<I', f.read(4))[0]
            if cmd == 0xC:
                no = struct.unpack('<I', f.read(4))[0]
                f.seek(pos + no)
                name = b''
                while True:
                    b = f.read(1)
                    if b == b'\x00': break
                    name += b
                if b'WeChatAntiRevoke' in name:
                    already = True
                    break
            f.seek(pos + cs)
        if already:
            continue

        insert_pos = slice_offset + 32 + sizeofcmds
        lc = struct.pack('<I', 0xC)
        lc += struct.pack('<I', cmd_size)
        lc += struct.pack('<I', 24)
        lc += struct.pack('<I', 2)
        lc += struct.pack('<I', 0x10000)
        lc += struct.pack('<I', 0x10000)
        lc += dylib_name
        while len(lc) < cmd_size:
            lc += b'\x00'

        f.seek(insert_pos)
        f.write(lc)
        f.seek(ncmds_pos)
        f.write(struct.pack('<I', ncmds + 1))
        f.seek(sizeofcmds_pos)
        f.write(struct.pack('<I', sizeofcmds + cmd_size))

print("ok")
INJECT_SCRIPT

    echo "[INFO] 注入完成"
}

resign_app() {
    echo "[INFO] 重签名..."
    codesign --force --sign - "$DYLIB_DST" 2>/dev/null
    codesign --force --sign - "$WECHAT_BIN" 2>/dev/null
    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
}

do_install() {
    print_banner
    check_environment

    echo "[INFO] 微信版本: 4.1.9 ($EXPECTED_VERSION)"

    # 检查是否已安装
    if [ -f "$DYLIB_DST" ]; then
        echo "[INFO] 检测到已安装，将重新安装..."
    fi

    kill_wechat

    # 尝试写入测试
    if ! touch "$DYLIB_DST" 2>/dev/null; then
        remove_provenance
    fi
    rm -f "$DYLIB_DST" 2>/dev/null || true

    compile_dylib
    inject_dylib
    resign_app

    echo ""
    echo "=============================="
    echo " 安装成功！"
    echo "=============================="
    echo ""
    echo " 功能: 对方撤回的消息将保留可见"
    echo "       自己撤回消息正常工作"
    echo ""
    echo " 打开微信: open /Applications/WeChat.app"
    echo " 卸载: $0 --uninstall"
    echo ""
}

do_uninstall() {
    print_banner
    echo "[INFO] 卸载防撤回插件..."

    kill_wechat

    # 删除 dylib
    rm -f "$DYLIB_DST" 2>/dev/null || true

    # 重新安装微信是最干净的卸载方式
    echo "[INFO] 建议重新安装微信以完全恢复原始状态"
    echo "[INFO] 或者删除 $DYLIB_DST 并重新签名"

    if [ -f "$DYLIB_DST" ]; then
        echo "[WARN] 无法删除 dylib，请手动重新安装微信"
    else
        resign_app 2>/dev/null || true
        echo ""
        echo "=============================="
        echo " 已卸载（dylib 已删除）"
        echo " 建议重新安装微信以彻底恢复"
        echo "=============================="
    fi
    echo ""
}

# ======================== 入口 ========================
case "${1:-}" in
    --uninstall|-u)
        do_uninstall
        ;;
    --help|-h)
        print_banner
        echo "用法:"
        echo "  $0              安装防撤回"
        echo "  $0 --uninstall  卸载"
        echo "  $0 --help       帮助"
        ;;
    "")
        do_install
        ;;
    *)
        echo "[ERROR] 未知参数: $1"
        exit 1
        ;;
esac
