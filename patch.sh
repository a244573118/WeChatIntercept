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

print_banner() {
    echo ""
    echo "=============================="
    echo " 微信防撤回安装工具"
    echo " 适用: macOS / 微信 4.1.9+"
    echo " 支持: Apple Silicon + Intel"
    echo "=============================="
    echo ""
}

check_environment() {
    if [ ! -d "$WECHAT_APP" ]; then
        echo "[ERROR] 未找到微信: $WECHAT_APP"
        exit 1
    fi

    SHORT_VER=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
    VERSION=$(defaults read "$WECHAT_APP/Contents/Info.plist" CFBundleVersion 2>/dev/null)

    if [ -z "$SHORT_VER" ]; then
        echo "[ERROR] 无法读取微信版本号，请检查 /Applications/WeChat.app 是否完整"
        exit 1
    fi

    # 大版本校验：仅支持 4.1.x 系列（C++ 架构）
    case "$SHORT_VER" in
        4.1.*)
            echo "[INFO] 微信版本: $SHORT_VER ($VERSION)"
            ;;
        *)
            echo "[ERROR] 不支持的微信大版本: $SHORT_VER"
            echo "        本工具仅支持 4.1.x 系列"
            echo "        旧版 3.x 请使用 Install.sh"
            echo "        如果你认为这是误判，请提交 issue"
            exit 1
            ;;
    esac

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
    local SRC_FILE="/tmp/antirevoke_hook_src.m"
    rm -f "$SRC_FILE"
    cat > "$SRC_FILE" << 'HOOK_SOURCE'
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <sys/mman.h>
#import <libkern/OSCacheControl.h>
#import <stdint.h>
#import <string.h>
#import <stdio.h>
#import <sys/stat.h>

// ── 日志 ─────────────────────────────────────────────────────
static FILE *g_logFile = NULL;

static void log_open(void) {
    g_logFile = fopen("/tmp/antirevoke_debug.log", "w");
}

#define ARLOG(fmt, ...) do { \
    if (g_logFile) { fprintf(g_logFile, "[AntiRevoke] " fmt "\n", ##__VA_ARGS__); fflush(g_logFile); } \
} while(0)

// ── 常量 ─────────────────────────────────────────────────────
static const char    *kDylibSuffix_Resources  = "Resources/wechat.dylib";
static const char    *kDylibSuffix_Frameworks = "Frameworks/wechat.dylib";
static const int32_t  kRevokeType    = 0x2712;   // 10002

// 配置文件路径：~/.config/antirevoke/config
// 格式：每行一个 key=value
// notify=1  开启通知（默认）
// notify=0  关闭通知
static char g_config_path[512] = {0};

// ── 版本地址表 ───────────────────────────────────────────────
static const uintptr_t k419_SlotVA_arm64   = 0x9301838;
static const uintptr_t k4110_FuncVA_arm64  = 0x44FFE20;
static const uintptr_t k4110_FuncVA_x86_64 = 0x4B4E9A0;
static const uintptr_t k419_FuncVA_x86_64  = 0x4AF08D0;

// ── 获取当前登录用户 ID ──────────────────────────────────────
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
        if (!contents || [contents count] == 0) return;

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
            ARLOG("用户: %s", g_my_id);
        }
    }
}

// ── 配置 ─────────────────────────────────────────────────────
static void init_config_path(void) {
    const char *home = getenv("HOME");
    if (home) {
        snprintf(g_config_path, sizeof(g_config_path), "%s/.config/antirevoke/config", home);
    }
}

static _Bool is_notify_enabled(void) {
    if (g_config_path[0] == '\0') return 1;  // 配置路径未初始化，默认开启
    FILE *f = fopen(g_config_path, "r");
    if (!f) return 1;  // 配置文件不存在，默认开启
    char line[128];
    _Bool enabled = 1;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "notify=0", 8) == 0) { enabled = 0; break; }
    }
    fclose(f);
    return enabled;
}

static void send_notification(const char *text) {
    if (!is_notify_enabled()) return;

    // 对英文双引号和反斜杠做转义
    char *escaped = (char *)malloc(1024);
    if (!escaped) return;
    int j = 0;
    for (int i = 0; text[i] && j < 1022; i++) {
        if (text[i] == '"' || text[i] == '\\') escaped[j++] = '\\';
        escaped[j++] = text[i];
    }
    escaped[j] = '\0';

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        FILE *sf = fopen("/tmp/antirevoke_notify.scpt", "w");
        if (sf) {
            fprintf(sf, "display notification \"%s\" with title \"WeChatIntercept\"\n", escaped);
            fclose(sf);
            system("osascript /tmp/antirevoke_notify.scpt");
        }
        free(escaped);
    });
}

// ── 检查 sender 偏移是否仍有效 ───────────────────────────────
// 仅检查前 4 字节是否为可打印 ASCII（微信 ID 总以可打印字符开头）
// 缩小检查范围避免误判撤回流程中的二次调用（其 sender 可能是 std::string 元数据）
static _Bool is_valid_sender(const char *s) {
    if (s[0] == '\0') return 1;  // 空字符串 = 自己撤回确认
    for (int i = 0; i < 4; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c > 0x7E) return 0;  // 非可打印字符
    }
    return 1;
}

// ── hook 函数 ────────────────────────────────────────────────
__attribute__((visibility("default")))
_Bool hook_isRevokeMessage(void *msg) {
    if (msg == NULL) return 0;

    int32_t msgType = *(int32_t *)((uint8_t *)msg + 0x0C);
    if (msgType != kRevokeType) return 0;

    load_my_user_id();

    const char *sender = (const char *)((uint8_t *)msg + 0x18);

    // 检查 sender 偏移是否仍有效（前 4 字节必须可打印 ASCII）
    // 失效时静默放行（return 1），避免影响撤回流程的内部状态
    // 真正的偏移失效会持续触发，达到阈值时弹一次"催更新"通知
    if (!is_valid_sender(sender)) {
        ARLOG("WARN: sender 区域非可打印 ASCII，跳过此次调用");

        // 累计失效次数，达到阈值时弹通知催更新（仅一次）
        static int g_invalid_count = 0;
        static _Bool g_warned = 0;
        g_invalid_count++;
        if (g_invalid_count >= 5 && !g_warned) {
            g_warned = 1;
            char *cmd = (char *)malloc(1024);
            if (cmd) {
                snprintf(cmd, 1024,
                    "osascript -e 'display notification \"sender 偏移已失效，快去催 WeChatIntercept 作者更新适配\" "
                    "with title \"WeChatIntercept 需更新\"' &");
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    system(cmd);
                    free(cmd);
                });
            }
        }
        return 1;  // 静默放行，不影响业务流程
    }

    // 自己撤回 → 放行
    if (sender[0] == '\0') return 1;
    if (g_my_id[0] != '\0' && strncmp(sender, g_my_id, strlen(g_my_id)) == 0) return 1;

    // 对方撤回 → 阻止
    ARLOG("拦截: %.20s", sender);

    // 提取通知内容
    char notify_text[256] = {0};

#if defined(__arm64__) || defined(__aarch64__)
    // arm64：从 msg+0x130 读取 XML body，提取 replacemsg（含用户昵称）
    uint64_t xml_ptr = *(uint64_t *)((uint8_t *)msg + 0x130);
    uint64_t xml_len = *(uint64_t *)((uint8_t *)msg + 0x138);
    if (xml_ptr > 0x100000000ULL && xml_len > 0 && xml_len < 4096) {
        const char *xml_body = (const char *)xml_ptr;
        const char *cs = strstr(xml_body, "<![CDATA[");
        const char *ce = cs ? strstr(cs, "]]>") : NULL;
        if (cs && ce) {
            cs += 9;
            size_t len = ce - cs;
            if (len > 0 && len < sizeof(notify_text) - 1) {
                memcpy(notify_text, cs, len);
                notify_text[len] = '\0';
            }
        }
    }
#endif

    char content[512] = {0};
    if (notify_text[0] != '\0')
        snprintf(content, sizeof(content), "拦截到%s", notify_text);
    else
        snprintf(content, sizeof(content), "拦截到 %s 撤回了一条消息", sender);

    send_notification(content);

    return 0;
}

// ── 查找 wechat.dylib 的 ASLR slide 和 mach_header ───────────
// 优先匹配 Resources/wechat.dylib（核心库），Frameworks/ 为 stub 不可用
static uintptr_t find_wechat_slide(const struct mach_header **out_header) {
    uint32_t count = _dyld_image_count();
    uintptr_t fallback = 0;
    const struct mach_header *fallback_header = NULL;
    size_t resLen = strlen(kDylibSuffix_Resources);
    size_t fwLen  = strlen(kDylibSuffix_Frameworks);

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= resLen && strcmp(name + len - resLen, kDylibSuffix_Resources) == 0) {
            if (out_header) *out_header = _dyld_get_image_header(i);
            return (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        }
        if (len >= fwLen && strcmp(name + len - fwLen, kDylibSuffix_Frameworks) == 0) {
            fallback = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
            fallback_header = _dyld_get_image_header(i);
        }
    }
    if (out_header) *out_header = fallback_header;
    return fallback;
}

// ── 解析 wechat.dylib 的 __TEXT 段范围 ───────────────────────
// 返回 1 = 成功，0 = 失败
static _Bool find_text_segment(const struct mach_header *header, uintptr_t slide,
                                uintptr_t *out_start, size_t *out_size) {
    if (!header) return 0;

    const uint8_t *p = (const uint8_t *)header;
    uint32_t ncmds;
    if (header->magic == MH_MAGIC_64) {
        p += sizeof(struct mach_header_64);
        ncmds = ((const struct mach_header_64 *)header)->ncmds;
    } else if (header->magic == MH_MAGIC) {
        p += sizeof(struct mach_header);
        ncmds = header->ncmds;
    } else {
        return 0;
    }

    for (uint32_t i = 0; i < ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)p;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                *out_start = (uintptr_t)seg->vmaddr + slide;
                *out_size = (size_t)seg->vmsize;
                return 1;
            }
        } else if (lc->cmd == LC_SEGMENT) {
            const struct segment_command *seg = (const struct segment_command *)p;
            if (strcmp(seg->segname, "__TEXT") == 0) {
                *out_start = (uintptr_t)seg->vmaddr + slide;
                *out_size = (size_t)seg->vmsize;
                return 1;
            }
        }
        p += lc->cmdsize;
    }
    return 0;
}

// ── 特征码搜索：在 __TEXT 段中查找 isRevokeMessage 函数 ──────
// arm64 特征：5 条指令的 isRevokeMessage（无 dispatch slot 的 4.1.10 形态）
//   LDR W8, [X0, #0xC]; MOV W9, #0x2712; CMP W8, W9; CSET W0, EQ; RET
// 返回函数 VA（slide + offset），未找到返回 0
static uintptr_t scan_isRevokeMessage_arm64(uintptr_t text_start, size_t text_size) {
    static const uint32_t pattern[5] = {
        0xB9400C08u, 0x5284E249u, 0x6B09011Fu, 0x1A9F17E0u, 0xD65F03C0u
    };
    const uint32_t *base = (const uint32_t *)text_start;
    size_t count = text_size / 4;
    if (count < 5) return 0;

    for (size_t i = 0; i + 5 <= count; i++) {
        if (base[i]   == pattern[0] &&
            base[i+1] == pattern[1] &&
            base[i+2] == pattern[2] &&
            base[i+3] == pattern[3] &&
            base[i+4] == pattern[4]) {
            return text_start + i * 4;
        }
    }
    return 0;
}

// x86_64 特征：完整函数（16 字节）
//   55 48 89 E5 (push rbp; mov rbp,rsp)
//   81 7F 0C 12 27 00 00 (cmp [rdi+0xC], 0x2712)
//   0F 94 C0 (sete al)
//   5D C3 (pop rbp; ret)
static uintptr_t scan_isRevokeMessage_x86_64(uintptr_t text_start, size_t text_size) {
    static const uint8_t pattern[] = {
        0x55, 0x48, 0x89, 0xE5,
        0x81, 0x7F, 0x0C, 0x12, 0x27, 0x00, 0x00,
        0x0F, 0x94, 0xC0,
        0x5D, 0xC3
    };
    const uint8_t *base = (const uint8_t *)text_start;
    if (text_size < sizeof(pattern)) return 0;

    for (size_t i = 0; i + sizeof(pattern) <= text_size; i++) {
        if (base[i] == pattern[0] &&
            memcmp(base + i, pattern, sizeof(pattern)) == 0) {
            return text_start + i;
        }
    }
    return 0;
}

// ── 版本检测 ─────────────────────────────────────────────────
// 已知支持的 build：4.1.9 (268602)、4.1.10 (268824)
static const char *kKnownBuilds[] = { "268602", "268824", NULL };

static _Bool is_known_build(const char *build) {
    if (!build) return 0;
    for (int i = 0; kKnownBuilds[i]; i++) {
        if (strcmp(build, kKnownBuilds[i]) == 0) return 1;
    }
    return 0;
}

// 读取 Info.plist 中的 CFBundleVersion + CFBundleShortVersionString
static void read_wechat_version(char *short_ver, size_t short_sz,
                                  char *build, size_t build_sz) {
    short_ver[0] = '\0';
    build[0] = '\0';
    @autoreleasepool {
        NSDictionary *info = [[NSBundle bundleWithPath:@"/Applications/WeChat.app"] infoDictionary];
        NSString *sv = info[@"CFBundleShortVersionString"];
        NSString *bv = info[@"CFBundleVersion"];
        if (sv) strncpy(short_ver, [sv UTF8String], short_sz - 1);
        if (bv) strncpy(build, [bv UTF8String], build_sz - 1);
    }
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

// ── Hook 安装失败时通知用户 ─────────────────────────────────
static void notify_install_failed(const char *short_ver, const char *build, _Bool known_build) {
    if (!is_notify_enabled()) return;

    char *cmd = (char *)malloc(2048);
    if (!cmd) return;

    char title[64];
    char body[512];

    if (known_build) {
        // 已知 build 但仍失败（极罕见）
        snprintf(title, sizeof(title), "WeChatIntercept 异常");
        snprintf(body, sizeof(body),
            "已知版本 %s (%s) hook 安装失败，请查看 /tmp/antirevoke_debug.log",
            short_ver, build);
    } else {
        // 未知 build：可能是版本变化或仅 build 号变化
        snprintf(title, sizeof(title), "WeChatIntercept 需更新");
        snprintf(body, sizeof(body),
            "微信版本 %s (build %s) 未适配，防撤回功能已失效。请前往 GitHub 获取最新脚本",
            short_ver, build);
    }

    // 转义 body 中的双引号和反斜杠
    char escaped[1024];
    int j = 0;
    for (int i = 0; body[i] && j < (int)sizeof(escaped) - 2; i++) {
        if (body[i] == '"' || body[i] == '\\') escaped[j++] = '\\';
        escaped[j++] = body[i];
    }
    escaped[j] = '\0';

    snprintf(cmd, 2048,
        "osascript -e 'display notification \"%s\" with title \"%s\"' &",
        escaped, title);

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        system(cmd);
        free(cmd);
    });
}

// ── 主 constructor ───────────────────────────────────────────
__attribute__((constructor))
static void hook_init(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{

        log_open();
        init_config_path();
        ARLOG("hook_init 启动");

        // 读取微信版本
        char short_ver[32] = {0};
        char build[32] = {0};
        read_wechat_version(short_ver, sizeof(short_ver), build, sizeof(build));
        _Bool known_build = is_known_build(build);
        ARLOG("微信版本: %s (build %s) %s", short_ver, build,
              known_build ? "[已适配]" : "[未适配]");

        const struct mach_header *header = NULL;
        uintptr_t slide = find_wechat_slide(&header);
        if (slide == 0) {
            ARLOG("ERROR: 未找到 wechat.dylib");
            notify_install_failed(short_ver, build, known_build);
            return;
        }

        // 解析 __TEXT 段范围（用于特征码搜索）
        uintptr_t text_start = 0;
        size_t text_size = 0;
        _Bool has_text = find_text_segment(header, slide, &text_start, &text_size);
        ARLOG("slide=0x%lx __TEXT=[0x%lx, +0x%zx) found=%d",
              (unsigned long)slide, (unsigned long)text_start, text_size, has_text);

        uintptr_t hook = (uintptr_t)&hook_isRevokeMessage;
        _Bool installed = 0;

#if defined(__arm64__) || defined(__aarch64__)
        // 1. 先尝试硬编码地址（快速路径）
        uintptr_t func_addr = 0;
        uintptr_t func_4110 = slide + k4110_FuncVA_arm64;
        uint32_t head_insn = *(volatile uint32_t *)func_4110;

        if (head_insn == 0xB9400C08u) {
            // 进一步验证完整 5 条指令特征码（避免误判）
            uint32_t *p = (uint32_t *)func_4110;
            if (p[1] == 0x5284E249u && p[2] == 0x6B09011Fu &&
                p[3] == 0x1A9F17E0u && p[4] == 0xD65F03C0u) {
                func_addr = func_4110;
                ARLOG("快速路径命中: 0x%lx", (unsigned long)func_addr);
            }
        }

        // 2. 快速路径失败 → 尝试 4.1.9 slot
        if (func_addr == 0) {
            void **slot = (void **)(slide + k419_SlotVA_arm64);
            // 简单验证：检查 slot 周围是否在 __DATA 段（不严格）
            // 先记录，后面如果特征码搜索也失败再尝试 slot
        }

        // 3. 特征码搜索（兜底）
        if (func_addr == 0 && has_text) {
            ARLOG("快速路径未命中，开始特征码搜索...");
            uintptr_t found = scan_isRevokeMessage_arm64(text_start, text_size);
            if (found) {
                func_addr = found;
                ARLOG("特征码搜索找到: 0x%lx (offset 0x%lx)",
                      (unsigned long)func_addr, (unsigned long)(func_addr - slide));
            }
        }

        // 4. 安装 trampoline
        if (func_addr != 0) {
            if (install_arm64_trampoline(func_addr, hook)) {
                ARLOG("arm64 trampoline 安装成功");
                installed = 1;
            }
        } else {
            // 5. 最后尝试 4.1.9 slot 方式
            void **slot = (void **)(slide + k419_SlotVA_arm64);
            uintptr_t page = (uintptr_t)slot & ~(uintptr_t)0x3FFF;
            kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, 0x4000,
                                          0, VM_PROT_READ | VM_PROT_WRITE);
            if (kr == KERN_SUCCESS) {
                *slot = (void *)hook;
                ARLOG("4.1.9 arm64 slot 写入（fallback）");
                installed = 1;
            }
        }

#elif defined(__x86_64__)
        uintptr_t func_addr = 0;
        uintptr_t func_4110_x86 = slide + k4110_FuncVA_x86_64;
        uintptr_t func_419_x86  = slide + k419_FuncVA_x86_64;
        const uint32_t kFuncHead = 0xE5894855u;

        // 1. 快速路径
        if (*(volatile uint32_t *)func_4110_x86 == kFuncHead) {
            func_addr = func_4110_x86;
        } else if (*(volatile uint32_t *)func_419_x86 == kFuncHead) {
            func_addr = func_419_x86;
        }

        // 2. 特征码搜索
        if (func_addr == 0 && has_text) {
            ARLOG("快速路径未命中，开始特征码搜索...");
            uintptr_t found = scan_isRevokeMessage_x86_64(text_start, text_size);
            if (found) {
                func_addr = found;
                ARLOG("特征码搜索找到: 0x%lx (offset 0x%lx)",
                      (unsigned long)func_addr, (unsigned long)(func_addr - slide));
            }
        }

        // 3. 安装 trampoline
        if (func_addr != 0) {
            if (install_x86_64_trampoline(func_addr, hook)) {
                ARLOG("x86_64 trampoline 安装成功");
                installed = 1;
            }
        }
#endif

        if (!installed) {
            ARLOG("ERROR: hook 安装失败 - 微信版本 %s (build %s) 未适配",
                  short_ver, build);
            notify_install_failed(short_ver, build, known_build);
        } else {
            ARLOG("就绪，等待撤回消息...");
        }
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
    local ENT_FILE="/tmp/antirevoke_ent.plist"
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

    # 创建默认配置（开启通知）
    local CONFIG_DIR="$HOME/.config/antirevoke"
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_DIR/config" ]; then
        echo "notify=1" > "$CONFIG_DIR/config"
    fi

    echo ""
    echo "=============================="
    echo " 安装成功！"
    echo "=============================="
    echo ""
    echo " 功能: 对方撤回的消息将保留可见"
    echo "       自己撤回消息正常工作"
    echo ""
    echo " 通知开关:"
    echo "   $0 openNotify   开启撤回通知"
    echo "   $0 closeNotify  关闭撤回通知"
    echo ""
    echo " 卸载: $0 --uninstall"
    echo ""
}

do_debug() {
    print_banner
    echo "[INFO] 调试模式（不安装 hook，仅签名允许 lldb attach）"

    check_environment
    kill_wechat
    remove_provenance

    # 删除已有的 hook dylib（确保无 hook）
    rm -f "$DYLIB_DST" 2>/dev/null || true

    # 签名（带 get-task-allow，允许 lldb attach）
    echo "[INFO] 重签名（注入调试 entitlements）..."
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
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

    codesign --force --deep --sign - "$WECHAT_APP" 2>/dev/null
    codesign --force --sign - --entitlements "$ENT_FILE" "$WECHAT_BIN" 2>/dev/null
    xattr -cr "$WECHAT_APP" 2>/dev/null || true
    rm -f "$ENT_FILE"

    echo "[INFO] 启动微信..."
    open "$WECHAT_APP"
    sleep 3

    echo ""
    echo "=============================="
    echo " 调试模式已启用"
    echo "=============================="
    echo ""
    echo " 微信无 hook，撤回流程完整执行"
    echo " 可使用 lldb attach 进行逆向分析"
    echo ""
    echo " 命令："
    echo "   lldb -p \$(pgrep -x WeChat)"
    echo "   image list wechat.dylib"
    echo "   # Resources 行地址 = slide"
    echo "   br set -a <slide+0x4D5FD70>"
    echo "   c"
    echo ""
    echo " 恢复防撤回: $0"
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

CONFIG_DIR="$HOME/.config/antirevoke"
CONFIG_FILE="$CONFIG_DIR/config"

do_open_notify() {
    mkdir -p "$CONFIG_DIR"
    if grep -q "^notify=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i '' 's/^notify=.*/notify=1/' "$CONFIG_FILE"
    else
        echo "notify=1" >> "$CONFIG_FILE"
    fi
    echo "[INFO] 撤回通知已开启"
}

do_close_notify() {
    mkdir -p "$CONFIG_DIR"
    if grep -q "^notify=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i '' 's/^notify=.*/notify=0/' "$CONFIG_FILE"
    else
        echo "notify=0" >> "$CONFIG_FILE"
    fi
    echo "[INFO] 撤回通知已关闭"
}

# ======================== 入口 ========================
case "${1:-}" in
    openNotify)
        do_open_notify
        ;;
    closeNotify)
        do_close_notify
        ;;
    --debug|-d)
        do_debug
        ;;
    --uninstall|-u)
        do_uninstall
        ;;
    --help|-h)
        print_banner
        echo "用法:"
        echo "  $0              安装防撤回"
        echo "  $0 openNotify   开启撤回通知"
        echo "  $0 closeNotify  关闭撤回通知"
        echo "  $0 --debug      调试模式（无 hook，允许 lldb）"
        echo "  $0 --uninstall  卸载"
        echo "  $0 --help       帮助"
        ;;
    "")
        do_install
        ;;
    *)
        echo "[ERROR] 未知参数: $1"
        echo "用法: $0 [openNotify|closeNotify|--uninstall|--debug|--help]"
        exit 1
        ;;
esac
