#!/bin/bash
#
# ============================================================
# 微信防撤回一键安装脚本
# ============================================================
#
# 适用版本: 微信 4.1.9 (CFBundleVersion: 268602)
#           微信 4.1.10 (CFBundleVersion: 268824)
# 适用平台: macOS (Apple Silicon + Intel)
# 依赖工具: clang, codesign, python3 (macOS 系统自带)
#
# 使用方法:
#   chmod +x patch.sh
#   ./patch.sh            # 安装防撤回
#   ./patch.sh --uninstall # 卸载（恢复原始微信）
#
# 原理:
#   通过 DYLD 注入一个运行时 hook 动态库，
#   拦截微信的 isRevokeMessage() 函数，
#   区分对方撤回和自己撤回：
#   - 对方撤回 → 返回 false（消息保留不被删除）
#   - 自己撤回 → 返回 true（正常处理，不会闪退）
#
#   4.1.9:  通过写入内建 hook dispatch slot (BSS 区域) 实现
#   4.1.10: dispatch slot 机制已移除，改用 inline trampoline patch
#
# ============================================================

set -e

WECHAT_APP="/Applications/WeChat.app"
WECHAT_BIN="$WECHAT_APP/Contents/MacOS/WeChat"
DYLIB_DST="$WECHAT_APP/Contents/Resources/WeChatAntiRevoke.dylib"
DYLIB_INSTALL_NAME="@executable_path/../Resources/WeChatAntiRevoke.dylib"

# 支持的版本列表
VERSION_419="268602"
VERSION_4110="268824"

print_banner() {
    echo ""
    echo "=============================="
    echo " 微信防撤回安装工具"
    echo " 适用: macOS / 微信 4.1.9 & 4.1.10"
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
    if [ "$VERSION" != "$VERSION_419" ] && [ "$VERSION" != "$VERSION_4110" ]; then
        echo "[ERROR] 不支持的微信版本 (实际 $VERSION，支持 $VERSION_419 / $VERSION_4110)"
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
    echo "[INFO] 尝试解除系统文件保护..."
    TMP_DIR=$(mktemp -d)
    tar --no-xattrs -cf - -C /Applications WeChat.app | tar -xf - -C "$TMP_DIR/"
    rm -rf "$WECHAT_APP"
    mv "$TMP_DIR/WeChat.app" "$WECHAT_APP"
    rm -rf "$TMP_DIR"

    # 递归清除残留 xattr（best-effort）
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
    sudo xattr -cr "$WECHAT_APP" 2>/dev/null || true

    # 检查结果（仅警告，不阻断安装）
    if xattr "$WECHAT_APP" 2>/dev/null | grep -q "com.apple.provenance"; then
        echo "[WARN] provenance 未能完全清除（macOS Sequoia 可能会自动重新附加）"
        echo "[INFO] 将通过 entitlements 绕过此限制"
    else
        echo "[INFO] 文件保护已解除"
    fi
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
#import <libkern/OSCacheControl.h>
#import <stdint.h>
#import <string.h>
#import <stdio.h>

// ── 日志（写入 /tmp/antirevoke_debug.log）────────────────────
static FILE *g_logFile = NULL;

static void log_open(void) {
    g_logFile = fopen("/tmp/antirevoke_debug.log", "w");
}

#define ARLOG(fmt, ...) do { \
    if (g_logFile) { fprintf(g_logFile, "[AntiRevoke] " fmt "\n", ##__VA_ARGS__); fflush(g_logFile); } \
} while(0)

// ── 公共常量 ────────────────────────────────────────────────
static const char    *kDylibSuffix_Resources  = "Resources/wechat.dylib";
static const char    *kDylibSuffix_Frameworks = "Frameworks/wechat.dylib";
static const int32_t  kRevokeType    = 0x2712;   // 10002

// ── 版本地址表 ───────────────────────────────────────────────
// 4.1.9  (CFBundleVersion 268602)
//   arm64:  hook dispatch slot VA = 0x9301838  (BSS，运行时可写)
//   x86_64: 暂不需要 slot（x86_64 直接 inline patch，同 4.1.10）
static const uintptr_t k419_SlotVA_arm64   = 0x9301838;

// 4.1.10 (CFBundleVersion 268824)  — dispatch slot 已移除，改用 inline trampoline
static const uintptr_t k4110_FuncVA_arm64  = 0x44FFE20;
static const uintptr_t k4110_FuncVA_x86_64 = 0x4B4E9A0;

// 4.1.9  x86_64 函数 VA（inline trampoline，与 4.1.10 流程相同）
static const uintptr_t k419_FuncVA_x86_64  = 0x4AF08D0;

// ── 获取当前登录用户 ID（完整字符串）─────────────────────────
// 懒加载：首次遇到撤回消息时从 app_data/login/ 读取最近登录的用户目录名
static char g_my_id[64] = {0};
static _Bool g_my_id_loaded = 0;

static void load_my_user_id(void) {
    if (g_my_id_loaded) return;
    g_my_id_loaded = 1;

    const char *home = getenv("HOME");
    if (!home) return;

    char loginDir[1024];
    snprintf(loginDir, sizeof(loginDir),
        "%s/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/login", home);

    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dirPath = [NSString stringWithUTF8String:loginDir];
        NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:nil];
        if (!contents || [contents count] == 0) {
            ARLOG("WARN: login 目录为空或不存在");
            return;
        }

        NSString *latestName = nil;
        NSDate *latestDate = nil;

        for (NSString *name in contents) {
            if ([name hasPrefix:@"."]) continue;
            NSString *fullPath = [dirPath stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;

            NSString *keyInfo = [fullPath stringByAppendingPathComponent:@"key_info.dat"];
            NSDictionary *attrs = [fm fileExistsAtPath:keyInfo]
                ? [fm attributesOfItemAtPath:keyInfo error:nil]
                : [fm attributesOfItemAtPath:fullPath error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];

            if (!latestDate || (modDate && [modDate compare:latestDate] == NSOrderedDescending)) {
                latestDate = modDate;
                latestName = name;
            }
        }

        if (latestName && [latestName length] >= 3 && [latestName length] < sizeof(g_my_id)) {
            strncpy(g_my_id, [latestName UTF8String], sizeof(g_my_id) - 1);
            ARLOG("当前用户 ID: %s", g_my_id);
        } else {
            ARLOG("WARN: 未能获取当前用户 ID");
        }
    }
}

// ── hook 函数（所有版本共用）────────────────────────────────
__attribute__((visibility("default")))
_Bool hook_isRevokeMessage(void *msg) {
    if (msg == NULL) return 0;

    int32_t msgType = *(int32_t *)((uint8_t *)msg + 0x0C);
    if (msgType != kRevokeType) return 0;

    // 懒加载当前用户 ID（首次遇到撤回消息时，登录一定已完成）
    load_my_user_id();

    // msg+0x18: 撤回操作发起者的 ID（std::string SSO buffer，直接存储字符内容）
    const char *sender = (const char *)((uint8_t *)msg + 0x18);

    // 判断逻辑：
    // 1. field18 为空 → 自己撤回确认 → 放行
    // 2. field18 == 自己 ID → 自己撤回 → 放行
    // 3. 其他 → 对方撤回 → 阻止
    if (sender[0] == '\0') {
        ARLOG("自己撤回（field=空），放行");
        return 1;
    }

    if (g_my_id[0] != '\0' && strncmp(sender, g_my_id, strlen(g_my_id)) == 0) {
        ARLOG("自己撤回（%s），放行", g_my_id);
        return 1;
    }

    ARLOG("对方撤回（%.20s），已阻止", sender);
    return 0;
}

// ── 查找 wechat.dylib 的 ASLR slide ─────────────────────────
// 优先匹配 Resources/wechat.dylib（核心库），Frameworks/ 为 stub 不可用
static uintptr_t find_wechat_slide(void) {
    uint32_t count = _dyld_image_count();
    uintptr_t fallback = 0;
    size_t resLen = strlen(kDylibSuffix_Resources);
    size_t fwLen  = strlen(kDylibSuffix_Frameworks);

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= resLen && strcmp(name + len - resLen, kDylibSuffix_Resources) == 0)
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        if (len >= fwLen && strcmp(name + len - fwLen, kDylibSuffix_Frameworks) == 0)
            fallback = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
    }
    return fallback;
}

// ── 内存保护工具 ─────────────────────────────────────────────
static kern_return_t make_rw(uintptr_t addr, size_t len) {
    uintptr_t page = addr & ~(uintptr_t)0x3FFF;
    size_t sz = (addr + len - page + 0x3FFF) & ~(size_t)0x3FFF;
    return vm_protect(mach_task_self(), (vm_address_t)page, sz, 0,
                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
}
static kern_return_t make_rx(uintptr_t addr, size_t len) {
    uintptr_t page = addr & ~(uintptr_t)0x3FFF;
    size_t sz = (addr + len - page + 0x3FFF) & ~(size_t)0x3FFF;
    return vm_protect(mach_task_self(), (vm_address_t)page, sz, 0,
                      VM_PROT_READ | VM_PROT_EXECUTE);
}

// ── arm64 inline trampoline（20 字节）─────────────────────────
static _Bool install_arm64_trampoline(uintptr_t func_addr, uintptr_t hook_addr) {
    kern_return_t kr = make_rw(func_addr, 20);
    if (kr != KERN_SUCCESS) { ARLOG("ERROR: make_rw kr=%d", kr); return 0; }

    uint32_t *p = (uint32_t *)func_addr;
    p[0] = 0x58000050u;  // LDR X16, #8
    p[1] = 0xD61F0200u;  // BR X16
    *(uint64_t *)(func_addr + 8) = (uint64_t)hook_addr;
    p[4] = 0xD503201Fu;  // NOP

    // 回读验证
    if (*(volatile uint32_t *)func_addr != 0x58000050u) {
        ARLOG("ERROR: 写入验证失败"); return 0;
    }

    sys_icache_invalidate((void *)func_addr, 20);
    make_rx(func_addr, 20);
    return 1;
}

// ── x86_64 inline trampoline（16 字节）───────────────────────
static _Bool install_x86_64_trampoline(uintptr_t func_addr, uintptr_t hook_addr) {
    kern_return_t kr = make_rw(func_addr, 16);
    if (kr != KERN_SUCCESS) { ARLOG("ERROR: x86_64 make_rw kr=%d", kr); return 0; }

    uint8_t *p = (uint8_t *)func_addr;
    p[0] = 0xFF; p[1] = 0x25;  // JMP [RIP+0]
    p[2] = p[3] = p[4] = p[5] = 0x00;
    *(uint64_t *)(func_addr + 6) = (uint64_t)hook_addr;
    p[14] = 0x90; p[15] = 0xC3;

    if (*(volatile uint8_t *)func_addr != 0xFF) {
        ARLOG("ERROR: x86_64 写入验证失败"); return 0;
    }

    __builtin___clear_cache((char *)func_addr, (char *)(func_addr + 16));
    make_rx(func_addr, 16);
    return 1;
}

// ── 主 constructor ───────────────────────────────────────────
__attribute__((constructor))
static void hook_init(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{

        log_open();
        ARLOG("hook_init 启动");

        uintptr_t slide = find_wechat_slide();
        if (slide == 0) { ARLOG("ERROR: 未找到 wechat.dylib"); return; }

        uintptr_t hook = (uintptr_t)&hook_isRevokeMessage;
        ARLOG("slide=0x%lx hook=0x%lx", (unsigned long)slide, (unsigned long)hook);

#if defined(__arm64__) || defined(__aarch64__)
        uintptr_t func_4110 = slide + k4110_FuncVA_arm64;
        uint32_t head_insn = *(volatile uint32_t *)func_4110;

        if (head_insn == 0xB9400C08u) {
            if (install_arm64_trampoline(func_4110, hook))
                ARLOG("4.1.10 arm64 trampoline 安装成功");
        } else {
            void **slot = (void **)(slide + k419_SlotVA_arm64);
            uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0x3FFF;
            vm_protect(mach_task_self(), (vm_address_t)page, 0x4000, 0, VM_PROT_READ | VM_PROT_WRITE);
            *slot = (void *)hook;
            ARLOG("4.1.9 arm64 slot 写入成功");
        }

#elif defined(__x86_64__)
        uintptr_t func_4110_x86 = slide + k4110_FuncVA_x86_64;
        uintptr_t func_419_x86  = slide + k419_FuncVA_x86_64;
        const uint32_t kFuncHead = 0xE5894855u;

        if (*(volatile uint32_t *)func_4110_x86 == kFuncHead) {
            if (install_x86_64_trampoline(func_4110_x86, hook))
                ARLOG("4.1.10 x86_64 trampoline 安装成功");
        } else if (*(volatile uint32_t *)func_419_x86 == kFuncHead) {
            if (install_x86_64_trampoline(func_419_x86, hook))
                ARLOG("4.1.9 x86_64 trampoline 安装成功");
        } else {
            ARLOG("ERROR: x86_64 函数地址未匹配");
        }
#endif
        ARLOG("就绪，等待撤回消息...");
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
    echo "[INFO] 重签名（注入 entitlements 绕过 Library Validation）..."

    # 创建 entitlements 文件
    local ENT_FILE=$(mktemp /tmp/entitlements_XXXXXX.plist)
    cat > "$ENT_FILE" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

    # 1. 签名 dylib（adhoc）
    codesign --force --sign - "$DYLIB_DST" 2>/dev/null

    # 2. 整体 deep 签名（先处理所有子组件）
    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null

    # 3. 最后单独给主程序签名并注入 entitlements（覆盖 deep 签名的结果）
    #    这样 entitlements 不会被后续操作覆盖
    codesign --force --sign - --entitlements "$ENT_FILE" "$WECHAT_BIN" 2>/dev/null

    # 清除 xattr（best-effort）
    xattr -cr "$WECHAT_APP" 2>/dev/null || true

    # 验证 entitlements 是否注入成功
    if codesign -d --entitlements - "$WECHAT_BIN" 2>&1 | grep -q "disable-library-validation"; then
        echo "[INFO] 重签名完成（Library Validation 已禁用）"
    else
        echo "[WARN] entitlements 可能未生效，请确认 SIP 状态"
    fi

    rm -f "$ENT_FILE"
}

verify_install() {
    echo "[INFO] 验证安装..."

    local FAIL=0

    # 1. dylib 文件存在
    if [ ! -f "$DYLIB_DST" ]; then
        echo "[ERROR] dylib 文件不存在: $DYLIB_DST"
        FAIL=1
    fi

    # 2. LC_LOAD_DYLIB 注入成功
    if ! otool -l "$WECHAT_BIN" 2>/dev/null | grep -q "WeChatAntiRevoke"; then
        echo "[ERROR] LC_LOAD_DYLIB 未注入到主程序"
        FAIL=1
    fi

    # 3. provenance 已清除
    if xattr "$WECHAT_APP" 2>/dev/null | grep -q "com.apple.provenance"; then
        echo "[WARN] WeChat.app 仍有 provenance 标记（重签名可能重新添加）"
        xattr -d com.apple.provenance "$WECHAT_APP" 2>/dev/null || true
    fi
    if xattr "$WECHAT_BIN" 2>/dev/null | grep -q "com.apple.provenance"; then
        echo "[WARN] 主程序仍有 provenance 标记"
        xattr -d com.apple.provenance "$WECHAT_BIN" 2>/dev/null || true
    fi
    if xattr "$DYLIB_DST" 2>/dev/null | grep -q "com.apple.provenance"; then
        echo "[WARN] dylib 仍有 provenance 标记"
        xattr -d com.apple.provenance "$DYLIB_DST" 2>/dev/null || true
    fi

    # 4. 签名验证
    if ! codesign -v "$DYLIB_DST" 2>/dev/null; then
        echo "[ERROR] dylib 签名无效"
        FAIL=1
    fi
    if ! codesign -v "$WECHAT_BIN" 2>/dev/null; then
        echo "[ERROR] 主程序签名无效"
        FAIL=1
    fi

    # 5. 运行时加载测试（启动微信、等待后检查 dylib 是否在内存中）
    echo "[INFO] 启动微信进行加载验证（约 8 秒）..."
    open "$WECHAT_APP"
    sleep 8

    local PID=$(pgrep -x WeChat 2>/dev/null)
    if [ -z "$PID" ]; then
        echo "[ERROR] 微信未能启动"
        FAIL=1
    else
        if vmmap "$PID" 2>/dev/null | grep -q "AntiRevoke"; then
            echo "[INFO] dylib 已成功加载到微信进程"
        else
            echo "[ERROR] dylib 未加载到微信进程！可能原因："
            echo "        - macOS 安全策略阻止"
            echo "        - 签名不一致"
            FAIL=1
        fi
    fi

    # 6. 检查 hook 安装日志（/tmp/antirevoke_debug.log）
    local LOG_FILE="/tmp/antirevoke_debug.log"
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        local LOG_OUTPUT=$(cat "$LOG_FILE")
        if echo "$LOG_OUTPUT" | grep -q "trampoline 安装完成"; then
            echo "[INFO] Hook 安装成功（trampoline 已写入）"
        elif echo "$LOG_OUTPUT" | grep -q "slot 写入完成"; then
            echo "[INFO] Hook 安装成功（slot 方式）"
        elif echo "$LOG_OUTPUT" | grep -q "写入验证失败"; then
            echo "[ERROR] trampoline 写入验证失败"
            FAIL=1
        elif echo "$LOG_OUTPUT" | grep -q "make_rw 失败"; then
            echo "[ERROR] 代码页写入被系统拒绝（vm_protect 失败）"
            FAIL=1
        elif echo "$LOG_OUTPUT" | grep -q "未找到 wechat.dylib"; then
            echo "[ERROR] 未找到 wechat.dylib"
            FAIL=1
        elif echo "$LOG_OUTPUT" | grep -q "均未匹配\|hook 失败"; then
            echo "[ERROR] hook 安装失败"
            FAIL=1
        fi
    else
        echo "[WARN] hook 日志文件未生成，hook_init 可能尚未执行"
    fi
    echo "[INFO] 调试日志: cat /tmp/antirevoke_debug.log"

    if [ "$FAIL" -ne 0 ]; then
        echo ""
        echo "[WARN] 安装验证未完全通过，请检查上述错误"
        echo ""
    fi
}

do_install() {
    print_banner
    check_environment

    VERSION=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)
    SHORT_VER=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    echo "[INFO] 微信版本: $SHORT_VER ($VERSION)"

    # 检查是否已安装
    if [ -f "$DYLIB_DST" ]; then
        echo "[INFO] 检测到已安装，将重新安装..."
    fi

    kill_wechat

    # 无条件清除 provenance（即使 .app 顶层无标记，内层文件也可能有）
    # 重打包是幂等操作，不会造成损坏
    remove_provenance
    rm -f "$DYLIB_DST" 2>/dev/null || true

    compile_dylib
    inject_dylib
    resign_app
    verify_install

    echo ""
    echo "=============================="
    echo " 安装成功！"
    echo "=============================="
    echo ""
    echo " 功能: 对方撤回的消息将保留可见"
    echo "       自己撤回消息正常工作"
    echo ""
    echo " 验证步骤:"
    echo "   1. 让别人发一条消息，然后撤回"
    echo "   2. 如果消息保留可见 → 防撤回生效"
    echo "   3. 如果消息仍被撤回 → 执行以下命令查看调试日志:"
    echo "      cat /tmp/antirevoke_debug.log"
    echo ""
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
