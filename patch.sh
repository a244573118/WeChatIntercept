#!/bin/bash
# 微信防撤回一键安装脚本
# 适用：微信 4.1.x (Apple Silicon + Intel)
# 依赖：clang / codesign / python3 (macOS 自带)
# 用法：./patch.sh [--monitor-install|--uninstall|--debug|--help]
# 详细原理 / 版本适配指南见 doc/reverse-engineering-guide.md

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

static FILE *g_logFile = NULL;

static void log_open(void) {
    g_logFile = fopen("/tmp/antirevoke_debug.log", "w");
}

#define ARLOG(fmt, ...) do { \
    if (g_logFile) { fprintf(g_logFile, "[AntiRevoke] " fmt "\n", ##__VA_ARGS__); fflush(g_logFile); } \
} while(0)

// 注意：Resources/wechat.dylib 是核心库（~140MB），Frameworks/ 下是 stub（~16KB），不能 hook 错
static const char    *kDylibSuffix_Resources  = "Resources/wechat.dylib";
static const char    *kDylibSuffix_Frameworks = "Frameworks/wechat.dylib";
static const int32_t  kRevokeType    = 0x2712;   // isRevokeMessage 比较的 MsgType 常量



// 已知 build 的硬编码地址（特征码搜索失败时的兜底）
static const uintptr_t k419_SlotVA_arm64   = 0x9301838;
static const uintptr_t k4110_FuncVA_arm64  = 0x44FFE20;
static const uintptr_t k4110_FuncVA_x86_64 = 0x4B4E9A0;
static const uintptr_t k419_FuncVA_x86_64  = 0x4AF08D0;

// 当前登录用户 wxid，用于区分"自己撤回"vs"对方撤回"
static char g_my_id[64] = {0};
static _Bool g_my_id_loaded = 0;

// 通过取 ~/Library/Containers/.../app_data/login/ 下最新修改的目录名判定
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



static void send_notification(const char *text) {
    // osascript 对 " 和 \ 敏感，必须转义
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

// 微信小版本升级 sender 偏移可能漂移；仅检查前 4 字节是否可打印 ASCII
// 失效时静默放行（return 1），不影响微信内部撤回流程；阈值后弹一次催更新通知
static _Bool is_valid_sender(const char *s) {
    if (s[0] == '\0') return 1;  // 空 = 自己撤回的内部回调
    for (int i = 0; i < 4; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c < 0x20 || c > 0x7E) return 0;
    }
    return 1;
}

// 入口：被微信 isRevokeMessage 替换。
// 返回 1 = 该消息是撤回（按原行为处理）；返回 0 = 阻止微信删除消息
__attribute__((visibility("default")))
_Bool hook_isRevokeMessage(void *msg) {
    if (msg == NULL) return 0;

    int32_t msgType = *(int32_t *)((uint8_t *)msg + 0x0C);
    if (msgType != kRevokeType) return 0;

    load_my_user_id();

    // 动态寻址 sender 字符串：+0x18 在新 build 中可能是标记字节
    // 从 +0x18 开始搜第一个可打印 C 字符串
    int sender_off = 0x18;
    {
        int found = 0;
        for (int off = 0x18; off <= 0x20; off++) {
            const unsigned char *p = (const unsigned char *)msg + off;
            if (p[0] >= 0x20 && p[0] <= 0x7E &&
                p[1] >= 0x20 && p[1] <= 0x7E &&
                p[2] >= 0x20 && p[2] <= 0x7E) {
                sender_off = off;
                found = 1;
                break;
            }
        }
        if (!found) {
            // 极端 fallback 仍然用 +0x18
            sender_off = 0x18;
        }
    }
    const char *sender = (const char *)((uint8_t *)msg + sender_off);

    if (!is_valid_sender(sender)) {
        ARLOG("WARN: sender 区域非可打印 ASCII，跳过此次调用");
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
        return 1;
    }

    // 自己撤回 → 放行（让微信正常处理）
    if (sender[0] == '\0') return 1;
    if (g_my_id[0] != '\0' && strncmp(sender, g_my_id, strlen(g_my_id)) == 0) return 1;

    // 对方撤回 → 阻止
    ARLOG("拦截: %.20s", sender);

    // 从 msg+0x130 (ptr) / +0x138 (len) 读撤回 XML
    char notify_text[256] = {0};

#if defined(__arm64__) || defined(__aarch64__)
    uint64_t xml_ptr = *(uint64_t *)((uint8_t *)msg + 0x130);
    uint64_t xml_len = *(uint64_t *)((uint8_t *)msg + 0x138);
    if (xml_ptr > 0x100000000ULL && xml_len > 0 && xml_len < 4096) {
        // CDATA 内容形如 "Macanzy" 撤回了一条消息
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

    // 反查 lldb monitor 写入的消息缓存（/tmp/wechat_msg_cache.tsv）
    char orig_content[512] = {0};
    _Bool has_orig = 0;
#if defined(__arm64__) || defined(__aarch64__)
    if (xml_ptr > 0x100000000ULL && xml_len > 0 && xml_len < 4096) {
        const char *xml_body = (const char *)xml_ptr;
        const char *p = strstr(xml_body, "<newmsgid>");
        uint64_t newmsgid = 0;
        if (p) {
            p += 10;
            int digits = 0;
            while (*p >= '0' && *p <= '9' && digits < 20) {
                newmsgid = newmsgid * 10 + (uint64_t)(*p - '0');
                p++; digits++;
            }
            if (digits == 0) newmsgid = 0;
        }
        if (newmsgid != 0) {
            FILE *cf = fopen("/tmp/wechat_msg_cache.tsv", "r");
            if (cf) {
                char line[1024];
                while (fgets(line, sizeof(line), cf)) {
                    char *t1 = strchr(line, '\t');
                    if (!t1) continue;
                    *t1 = '\0';
                    uint64_t row_svrid = 0;
                    int d2 = 0;
                    for (const char *q = line; *q >= '0' && *q <= '9' && d2 < 20; q++, d2++)
                        row_svrid = row_svrid * 10 + (uint64_t)(*q - '0');
                    if (d2 == 0 || row_svrid != newmsgid) continue;
                    char *t2 = strchr(t1 + 1, '\t');
                    if (!t2) continue;
                    char *nl = strchr(t2 + 1, '\n');
                    if (nl) *nl = '\0';
                    strncpy(orig_content, t2 + 1, sizeof(orig_content) - 1);
                    has_orig = (orig_content[0] != '\0');
                }
                fclose(cf);
            }
            ARLOG("撤回反查: svrid=%llu %s",
                  (unsigned long long)newmsgid, has_orig ? "命中" : "未命中");
        }
    }
#endif

    // 非文本消息描述模板 → 占位符
    if (has_orig) {
        struct { const char *needle; const char *replace; } kReplaces[] = {
            {"发了一张图片", "[图片]"}, {"发了一段视频", "[视频]"},
            {"发了一个文件", "[文件]"}, {"发了一段语音", "[语音]"},
            {"发了一条语音消息", "[语音]"}, {"发了一个表情", "[表情]"},
            {"发了一个视频号", "[视频号]"}, {"发了一张名片", "[名片]"},
            {"发了一个位置", "[位置]"}, {"发了一个红包", "[红包]"},
            {"发了一个链接", "[链接]"}, {"发了一个小程序", "[小程序]"},
            {NULL, NULL},
        };
        for (int i = 0; kReplaces[i].needle; i++) {
            if (strstr(orig_content, kReplaces[i].needle)) {
                strncpy(orig_content, kReplaces[i].replace, sizeof(orig_content) - 1);
                break;
            }
        }
    }

    // 从 notify_text 抽纯昵称：剥 "撤回了" 后缀 + 首尾空格 + 英文双引号
    char nick[128] = {0};
    if (notify_text[0] != '\0') {
        const char *p = strstr(notify_text, "撤回了");
        if (p && p > notify_text) {
            const char *start = notify_text;
            size_t nlen = (size_t)(p - notify_text);
            while (nlen > 0 && start[nlen - 1] == ' ') nlen--;
            while (nlen > 0 && *start == ' ') { start++; nlen--; }
            if (nlen >= 2 && start[0] == '"' && start[nlen - 1] == '"') { start++; nlen -= 2; }
            if (nlen > 0 && nlen < sizeof(nick)) { memcpy(nick, start, nlen); nick[nlen] = '\0'; }
        }
    }
    const char *who = (nick[0] != '\0') ? nick : sender;

    char content[768] = {0};
    if (has_orig) {
        snprintf(content, sizeof(content), "拦截到「%s」撤回了一条消息：%s", who, orig_content);
    } else {
        snprintf(content, sizeof(content), "拦截到「%s」撤回了一条消息", who);
    }

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

// arm64 isRevokeMessage 特征码：LDR W8,[X0,#C]; MOV W9,#0x2712; CMP; CSET; RET
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

// x86_64 isRevokeMessage 特征码
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

static const char *kKnownBuilds[] = { "268602", "268824", NULL };

static _Bool is_known_build(const char *build) {
    if (!build) return 0;
    for (int i = 0; kKnownBuilds[i]; i++) {
        if (strcmp(build, kKnownBuilds[i]) == 0) return 1;
    }
    return 0;
}

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

// arm64: LDR X16,#8; BR X16; <addr64>; NOP  — 共 20 字节覆盖原函数入口
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

// x86_64: JMP [RIP+0]; <addr64>; NOP; RET  — 共 16 字节
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

static void notify_install_failed(const char *short_ver, const char *build, _Bool known_build) {

    char *cmd = (char *)malloc(2048);
    if (!cmd) return;

    char title[64];
    char body[512];

    if (known_build) {
        snprintf(title, sizeof(title), "WeChatIntercept 异常");
        snprintf(body, sizeof(body),
            "已知版本 %s (%s) hook 安装失败，请查看 /tmp/antirevoke_debug.log",
            short_ver, build);
    } else {
        snprintf(title, sizeof(title), "WeChatIntercept 需更新");
        snprintf(body, sizeof(body),
            "微信版本 %s (build %s) 未适配，防撤回功能已失效。请前往 GitHub 获取最新脚本",
            short_ver, build);
    }

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
        ARLOG("hook_init 启动");

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

        uintptr_t text_start = 0;
        size_t text_size = 0;
        _Bool has_text = find_text_segment(header, slide, &text_start, &text_size);
        ARLOG("slide=0x%lx __TEXT=[0x%lx, +0x%zx) found=%d",
              (unsigned long)slide, (unsigned long)text_start, text_size, has_text);

        uintptr_t hook = (uintptr_t)&hook_isRevokeMessage;
        _Bool installed = 0;

#if defined(__arm64__) || defined(__aarch64__)
        // 三级查找：硬编码快速路径 → 特征码搜索 → 4.1.9 slot fallback
        uintptr_t func_addr = 0;
        uintptr_t func_4110 = slide + k4110_FuncVA_arm64;
        uint32_t head_insn = *(volatile uint32_t *)func_4110;

        if (head_insn == 0xB9400C08u) {
            uint32_t *p = (uint32_t *)func_4110;
            if (p[1] == 0x5284E249u && p[2] == 0x6B09011Fu &&
                p[3] == 0x1A9F17E0u && p[4] == 0xD65F03C0u) {
                func_addr = func_4110;
                ARLOG("快速路径命中: 0x%lx", (unsigned long)func_addr);
            }
        }

        if (func_addr == 0 && has_text) {
            ARLOG("快速路径未命中，开始特征码搜索...");
            uintptr_t found = scan_isRevokeMessage_arm64(text_start, text_size);
            if (found) {
                func_addr = found;
                ARLOG("特征码搜索找到: 0x%lx (offset 0x%lx)",
                      (unsigned long)func_addr, (unsigned long)(func_addr - slide));
            }
        }

        if (func_addr != 0) {
            if (install_arm64_trampoline(func_addr, hook)) {
                ARLOG("arm64 trampoline 安装成功");
                installed = 1;
            }
        } else {
            // 4.1.9 slot fallback
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

        if (*(volatile uint32_t *)func_4110_x86 == kFuncHead) {
            func_addr = func_4110_x86;
        } else if (*(volatile uint32_t *)func_419_x86 == kFuncHead) {
            func_addr = func_419_x86;
        }

        if (func_addr == 0 && has_text) {
            ARLOG("快速路径未命中，开始特征码搜索...");
            uintptr_t found = scan_isRevokeMessage_x86_64(text_start, text_size);
            if (found) {
                func_addr = found;
                ARLOG("特征码搜索找到: 0x%lx (offset 0x%lx)",
                      (unsigned long)func_addr, (unsigned long)(func_addr - slide));
            }
        }

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
    # get-task-allow 允许 lldb attach（用于 monitor.sh 写消息缓存供撤回反查）
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
    <key>com.apple.security.get-task-allow</key>
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



    echo ""
    echo "=============================="
    echo " 安装成功！"
    echo "=============================="
    echo ""
    echo " 功能: 对方撤回的消息将保留可见"
    echo "       自己撤回消息正常工作"
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

# ======================== 消息监听（撤回原文）========================

MONITOR_INSTALL_DIR="$HOME/.local/share/wechatintercept"

deploy_monitor_files() {
    mkdir -p "$MONITOR_INSTALL_DIR"

    # wechat_msg_monitor.py
    cat > "$MONITOR_INSTALL_DIR/wechat_msg_monitor.py" << 'MONITOR_PY'
# -*- coding: utf-8 -*-
"""
WeChat 消息监听器（lldb Python 脚本）
在 wechat.dylib __TEXT 段扫描 CMessageWrap 虚方法特征码，
断点命中时读消息字段写入 TSV 缓存供 dylib 反查撤回原文。
用法：./monitor.sh 或 ./monitor.sh --install
"""

import lldb
import struct
import datetime

# CMessageWrap 虚方法（257712）特征码（4.1.10 实测）
# PREFIX 4条 + 通配 bl(4字节) + SUFFIX 1条
PATTERN_PREFIX = bytes.fromhex("f44fbea9" "fd7b01a9" "fd430091" "f30301aa")
PATTERN_SUFFIX = bytes.fromhex("683a40f9")
PATTERN_GAP = 4

# 消息对象字段偏移（4.1.10 验证；微信升级后可能变化）
OFF_FLAG1       = 0x28
OFF_FLAG2       = 0x2c
OFF_CONTENT_PTR = 0x40   # wrapper ptr; wrapper+0x00 → content char*
OFF_CREATE_TIME = 0x48
OFF_MSG_LOCAL   = 0x4c
OFF_MSG_SVR     = 0x50   # int64, 与撤回 XML <newmsgid> 对应
OFF_FROM_PTR    = 0x08   # wrapper ptr; wrapper+0x08 → wxid char*

WRAPPER_DATA_PTR = 0x08

_g_msg_count = 0
_g_seen_svrid = set()
_g_debug_dump = False

# 缓存文件：dylib 反查撤回原文用。svrid 十进制，字段 \t 分隔，原子 rename 写入
CACHE_FILE = "/tmp/wechat_msg_cache.tsv"
_CACHE_MAX_LINES = 500
_g_cache_lines = []


def _sanitize_field(s):
    if not s:
        return ""
    return s.replace("\t", " ").replace("\n", " ").replace("\r", " ")


def _strip_sender_prefix(content):
    # 微信 +0x40 存的是 "<昵称> : <正文>" 格式，剥掉前缀只留正文
    if not content:
        return content
    idx = content.find(" : ")
    if idx > 0 and idx < 64:  # 昵称不会超过 64 字符
        return content[idx + 3:]
    return content


def _is_valid_content(stripped, from_user):
    if not stripped or len(stripped) < 2:
        return False
    if stripped == from_user:
        return False
    if stripped.startswith("<"):
        return False
    return True


def _cache_append(svrid, from_user, content):
    if svrid == 0 or not content:
        return
    try:
        body = _strip_sender_prefix(content)
        line = "{}\t{}\t{}\n".format(
            svrid,
            _sanitize_field(from_user)[:63],
            _sanitize_field(body)[:511],
        )
        _g_cache_lines.append(line)
        if len(_g_cache_lines) > _CACHE_MAX_LINES:
            del _g_cache_lines[: len(_g_cache_lines) - _CACHE_MAX_LINES]

        # 原子写，避免 dylib 读到半行
        tmp = CACHE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8", errors="replace") as f:
            f.writelines(_g_cache_lines)
        import os
        os.replace(tmp, CACHE_FILE)
    except Exception as e:
        print("    [cache] write failed: {}".format(e))


def _read_mem(process, addr, size):
    if addr == 0:
        return None
    err = lldb.SBError()
    data = process.ReadMemory(addr, size, err)
    if not err.Success():
        return None
    return data


def _read_u32(process, addr):
    data = _read_mem(process, addr, 4)
    if data is None:
        return None
    return struct.unpack("<I", data)[0]


def _read_u64(process, addr):
    data = _read_mem(process, addr, 8)
    if data is None:
        return None
    return struct.unpack("<Q", data)[0]


def _read_cstring(process, addr, max_len=256):
    if addr == 0:
        return ""
    data = _read_mem(process, addr, max_len)
    if data is None:
        return ""
    nul = data.find(b"\x00")
    if nul >= 0:
        data = data[:nul]
    try:
        return data.decode("utf-8", errors="replace")
    except Exception:
        return repr(data)


def _read_std_string_via_wrapper(process, wrapper_ptr):
    # wrapper 结构: +0x00 vtable, +0x08 data ptr
    if wrapper_ptr == 0:
        return ""
    data_ptr = _read_u64(process, wrapper_ptr + WRAPPER_DATA_PTR)
    if data_ptr is None or data_ptr == 0:
        return ""

    # 简化：不区分 char*/SSO，直接当 C 字符串读
    s = _read_cstring(process, data_ptr, max_len=512)
    return s


def _read_std_string_inplace(process, addr):
    # libc++ std::string 24字节布局: LSB of byte[23] == 0 → SSO, == 1 → heap
    data = _read_mem(process, addr, 24)
    if data is None:
        return ""
    last_byte = data[23]
    if last_byte & 0x01 == 0:
        # SSO（最低位=0）
        size = last_byte >> 1
        if size > 22:
            return ""
        return data[:size].decode("utf-8", errors="replace")
    else:
        # 长字符串
        ptr = struct.unpack("<Q", data[0:8])[0]
        size = struct.unpack("<Q", data[8:16])[0]
        if size > 4096:
            return ""
        body = _read_mem(process, ptr, size)
        if body is None:
            return ""
        return body.decode("utf-8", errors="replace")



def _try_read_content(process, msg_obj):
    # +0x40 是 std::string inplace（libc++ [data_ptr][size][cap|0x80...]）
    # 注意：断点命中瞬间 data_ptr 指向的内存可能还没就绪（时序问题），
    # 所以尝试两次读取：第一次失败就 fallback，最后再试一次
    def _try_str40():
        # +0x40 存的是指针 → 指向 std::string 结构
        ptr40 = _read_u64(process, msg_obj + 0x40)
        if not ptr40 or ptr40 < 0x100000000 or ptr40 > 0x10000000000:
            return ""
        raw = _read_mem(process, ptr40, 24)
        if not raw or len(raw) < 24:
            return ""
        dp = struct.unpack("<Q", raw[0:8])[0]
        sz = struct.unpack("<Q", raw[8:16])[0]
        # 长字符串：dp 是堆指针，sz 是长度
        if 0x100000000 < dp < 0x10000000000 and 0 < sz < 4096:
            text = _read_cstring(process, dp, min(int(sz) + 1, 512))
            if text and len(text) >= 2:
                return text
        # SSO：数据直接在 raw[0:22]
        nul = raw.find(b"\x00", 0, 22)
        sso_data = raw[:nul] if nul >= 0 else raw[:22]
        if sso_data and len(sso_data) >= 2:
            try:
                return sso_data.decode("utf-8", errors="strict")
            except UnicodeDecodeError:
                pass
        return ""

    t = _try_str40()
    if t:
        return (t, "+0x40(str)")

    return ("", "")


def on_msg_hit(frame, bp_loc, dict_):
    # 返回 False = 自动 continue（不停在 lldb）
    global _g_msg_count, _g_seen_svrid

    process = frame.GetThread().GetProcess()

    # x19 = msg obj; callee-saved, 在 +12 (mov x19,x1) 后已就绪
    x19 = frame.FindRegister("x19").GetValueAsUnsigned()
    if x19 == 0:
        return False

    msg_obj = x19
    if msg_obj < 0x100000000 or msg_obj > 0x1000000000000:
        return False

    create_time = _read_u32(process, msg_obj + OFF_CREATE_TIME)
    msg_local = _read_u32(process, msg_obj + OFF_MSG_LOCAL)
    msg_svr_lo = _read_u32(process, msg_obj + OFF_MSG_SVR)
    msg_svr_hi = _read_u32(process, msg_obj + OFF_MSG_SVR + 4)
    if create_time is None or msg_svr_lo is None or msg_svr_hi is None:
        return False
    msg_svr = (msg_svr_hi << 32) | msg_svr_lo

    if create_time < 1577836800 or create_time > 1893456000:  # 2020~2030
        return False

    if msg_svr in _g_seen_svrid:
        return False
    if msg_svr != 0:
        _g_seen_svrid.add(msg_svr)
        if len(_g_seen_svrid) > 1000:
            _g_seen_svrid = set(list(_g_seen_svrid)[-500:])

    # from: +0x08 wrapper, wrapper+0x08 才是字符串
    from_wrapper = _read_u64(process, msg_obj + OFF_FROM_PTR)
    from_user = _read_std_string_via_wrapper(process, from_wrapper) if from_wrapper else ""

    flag1 = _read_u32(process, msg_obj + OFF_FLAG1)
    flag2 = _read_u32(process, msg_obj + OFF_FLAG2)
    subtype_vtbl = _read_u64(process, msg_obj + 0x10)

    # flag2=1: +0x40 → ptr → std::string（已验证）
    # flag2=2: 不同类结构，尝试扩大范围搜索
    content, content_off = _try_read_content(process, msg_obj)

    try:
        ts = datetime.datetime.fromtimestamp(create_time).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        ts = str(create_time)

    _g_msg_count += 1
    print("─" * 60)
    print("[wx_msg #{}] {}".format(_g_msg_count, ts))
    print("  obj      : 0x{:016x}".format(msg_obj))
    print("  svrid    : 0x{:016x}".format(msg_svr))
    print("  localid  : 0x{:08x}".format(msg_local or 0))
    print("  flag     : 0x{:x} / 0x{:x}".format(flag1 or 0, flag2 or 0))
    print("  subtype  : 0x{:x}".format(subtype_vtbl or 0))  # +0x10 处的 vtable，用于区分消息类型
    print("  from     : {}".format(from_user))
    if content:
        print("  content@{}: {}".format(content_off, content[:200]))
    else:
        print("  content  : <empty>")



    # 写缓存前排除误读
    if content and msg_svr != 0:
        stripped = _strip_sender_prefix(content)
        if stripped and _is_valid_content(stripped, from_user):
            _cache_append(msg_svr, from_user, content)

    if _g_debug_dump:
        _dump_msg_object(process, msg_obj)
        # must be in breakpoint context or object freed
        _deep_scan(process, msg_obj)

    return False


def _dump_msg_object(process, addr, obj_size=0x100):
    raw = _read_mem(process, addr, obj_size)
    if raw is None:
        print("    [dump] 读取失败")
        return
    print("    [dump] obj @ 0x{:x} ({} bytes):".format(addr, obj_size))
    for off in range(0, obj_size, 16):
        line = raw[off:off + 16]
        hex_part = " ".join("{:02x}".format(b) for b in line)
        ascii_part = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in line)
        print("      +0x{:03x}: {}  {}".format(off, hex_part, ascii_part))

    print("    [deref] 候选指针字段:")
    for off in range(0, obj_size, 8):
        if off + 8 > len(raw):
            break
        ptr = struct.unpack("<Q", raw[off:off + 8])[0]
        if ptr < 0x100000000 or ptr > 0x10000000000:
            continue
        sub = _read_mem(process, ptr, 64)
        if sub is None:
            continue
        printable = sum(1 for b in sub[:32] if 0x20 <= b < 0x7F)
        if printable < 4:
            continue
        ascii_part = "".join(chr(b) if 0x20 <= b < 0x7F else "." for b in sub[:48])
        print("      +0x{:03x} -> 0x{:x}: {}".format(off, ptr, ascii_part))


def scan_pattern(process, start_addr, size, max_size=512 * 1024 * 1024):
    if size > max_size:
        size = max_size

    chunk_size = 4 * 1024 * 1024  # 4MB
    overlap = len(PATTERN_PREFIX) + PATTERN_GAP + len(PATTERN_SUFFIX)

    pos = 0
    chunks_read = 0
    chunks_failed = 0
    prefix_hits = 0  # PREFIX 匹配但 SUFFIX 不匹配的次数
    bytes_scanned = 0

    while pos < size:
        read_size = min(chunk_size + overlap, size - pos)
        data = _read_mem(process, start_addr + pos, read_size)
        if data is None:
            chunks_failed += 1
            pos += chunk_size
            continue

        chunks_read += 1
        bytes_scanned += len(data)

        idx = 0
        while True:
            i = data.find(PATTERN_PREFIX, idx)
            if i < 0:
                break
            prefix_hits += 1
            suffix_pos = i + len(PATTERN_PREFIX) + PATTERN_GAP
            if suffix_pos + len(PATTERN_SUFFIX) <= len(data):
                if data[suffix_pos:suffix_pos + len(PATTERN_SUFFIX)] == PATTERN_SUFFIX:
                    print("    扫描完成: chunks ok={} fail={} bytes={} prefix_hits={}".format(
                        chunks_read, chunks_failed, bytes_scanned, prefix_hits))
                    return start_addr + pos + i
            idx = i + 1

        pos += chunk_size

    print("    扫描完成（未找到）: chunks ok={} fail={} bytes={} prefix_hits={}".format(
        chunks_read, chunks_failed, bytes_scanned, prefix_hits))
    return 0


def find_wechat_dylib_text(target):
    # NOTE: 微信 4.1.x 有两个 wechat.dylib (Resources/ 核心 vs Frameworks/ stub)
    # 必须用完整路径区分
    candidates = []
    for module in target.module_iter():
        spec = module.GetFileSpec()
        filename = spec.GetFilename() or ""
        if filename != "wechat.dylib":
            continue
        directory = spec.GetDirectory() or ""
        full_path = directory + "/" + filename
        for sec in module.section_iter():
            if sec.GetName() == "__TEXT":
                load_addr = sec.GetLoadAddress(target)
                size = sec.GetByteSize()
                candidates.append((full_path, load_addr, size))
                break

    if not candidates:
        return (0, 0)

    for path, addr, size in candidates:
        if "/Resources/" in path:
            print("    [match] {} __TEXT @ 0x{:x} size=0x{:x}".format(path, addr, size))
            return (addr, size)

    candidates.sort(key=lambda x: x[2], reverse=True)
    path, addr, size = candidates[0]
    print("    [fallback] {} __TEXT @ 0x{:x} size=0x{:x}".format(path, addr, size))
    return (addr, size)


def cmd_start(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target:
        result.SetError("没有 target，先 attach 微信进程")
        return
    process = target.GetProcess()
    if not process or not process.IsValid():
        result.SetError("没有 process")
        return

    print(">>> 扫描 wechat.dylib __TEXT 特征码 ...")
    text_addr, text_size = find_wechat_dylib_text(target)
    if text_addr == 0:
        print("    候选模块：")
        for module in target.module_iter():
            spec = module.GetFileSpec()
            fn = spec.GetFilename() or ""
            if "wechat" in fn.lower():
                print("      - {}/{}".format(spec.GetDirectory() or "", fn))
        result.SetError("未找到 wechat.dylib __TEXT 段（确认 wechat.dylib 已加载）")
        return
    if text_size < 1024 * 1024:
        print("    [WARN] __TEXT size=0x{:x} 异常偏小，可能匹配到 stub".format(text_size))

    func_addr = scan_pattern(process, text_addr, text_size)
    if func_addr == 0:
        result.SetError("特征码未匹配（可能版本不一致，需更新 PATTERN）")
        return
    # 断点在 +20: +12 mov x19,x1 已执行(obj ready), +16 bl已完成(content ready)
    # 不能更早，否则 x19 或 content 还没就绪
    BP_OFFSET_FROM_FUNC_HEAD = 20
    bp_addr = func_addr + BP_OFFSET_FROM_FUNC_HEAD

    print("    msg func @ 0x{:x}（断点 @ 0x{:x} = +{}）".format(
        func_addr, bp_addr, BP_OFFSET_FROM_FUNC_HEAD))

    bp = target.BreakpointCreateByAddress(bp_addr)
    if not bp.IsValid():
        result.SetError("断点创建失败")
        return
    bp.SetScriptCallbackFunction("wechat_msg_monitor.on_msg_hit")
    bp.SetAutoContinue(True)
    print(">>> 断点 #{} 已设置 @ 0x{:x}（自动 continue）".format(bp.GetID(), bp_addr))
    print(">>> 输入 'continue' 让微信跑起来；收到的消息会打印在这里")
    print(">>> 停止监听：bp delete {}".format(bp.GetID()))


def cmd_stop(debugger, command, result, internal_dict):
    target = debugger.GetSelectedTarget()
    if not target:
        return
    print("请手动 'breakpoint delete <id>' 删除断点")


def cmd_stats(debugger, command, result, internal_dict):
    print("已捕获消息数: {}".format(_g_msg_count))
    print("去重表大小  : {}".format(len(_g_seen_svrid)))
    print("调试 dump 模式: {}".format("ON" if _g_debug_dump else "OFF"))


def cmd_debug_on(debugger, command, result, internal_dict):
    global _g_debug_dump
    _g_debug_dump = True
    print("[debug] dump 模式已打开。下次命中会输出原始字节。")


def cmd_debug_off(debugger, command, result, internal_dict):
    global _g_debug_dump
    _g_debug_dump = False
    print("[debug] dump 模式已关闭。")


def _deep_scan(process, addr, scan_size=0x200):
    print("    [deep_scan] @ 0x{:x}".format(addr))
    raw = _read_mem(process, addr, scan_size)
    if raw is None:
        print("    [deep_scan] 读取失败")
        return

    found = 0
    seen_ptrs = set()
    seen_ptrs.add(addr)
    for off in range(0, len(raw), 8):
        if off + 8 > len(raw):
            break
        ptr = struct.unpack("<Q", raw[off:off + 8])[0]
        if ptr < 0x100000000 or ptr > 0x10000000000:
            continue
        if ptr in seen_ptrs:
            continue
        seen_ptrs.add(ptr)

        sub = _read_mem(process, ptr, 96)
        if sub is None:
            continue

        for start in range(0, min(64, len(sub))):
            ok = 0
            for i in range(start, min(start + 8, len(sub))):
                b = sub[i]
                if 0x20 <= b < 0x7F:
                    ok += 1
                else:
                    break
            if ok >= 4:  # 放宽到 4 个连续字符
                end = start
                for i in range(start, min(start + 80, len(sub))):
                    if sub[i] == 0:
                        break
                    end = i + 1
                txt = sub[start:end]
                try:
                    s = txt.decode("utf-8", errors="replace")
                    print("      L1 +0x{:03x} -> 0x{:x} +0x{:02x}: {}".format(off, ptr, start, s))
                    found += 1
                except Exception:
                    pass
                break

        for sub_off in range(0, len(sub), 8):
            if sub_off + 8 > len(sub):
                break
            sub_ptr = struct.unpack("<Q", sub[sub_off:sub_off + 8])[0]
            if sub_ptr < 0x100000000 or sub_ptr > 0x10000000000:
                continue
            if sub_ptr in seen_ptrs:
                continue
            seen_ptrs.add(sub_ptr)
            sub2 = _read_mem(process, sub_ptr, 96)
            if sub2 is None:
                continue
            ok = 0
            for i in range(min(8, len(sub2))):
                if 0x20 <= sub2[i] < 0x7F:
                    ok += 1
                else:
                    break
            if ok >= 4:
                end = 0
                for i in range(min(80, len(sub2))):
                    if sub2[i] == 0:
                        break
                    end = i + 1
                txt = sub2[:end]
                try:
                    s = txt.decode("utf-8", errors="replace")
                    print("      L2 +0x{:03x}/+0x{:02x} -> 0x{:x}: {}".format(off, sub_off, sub_ptr, s))
                    found += 1
                except Exception:
                    pass

    if found == 0:
        print("    [deep_scan] 未发现可读字符串")
    else:
        print("    [deep_scan] 共 {} 处".format(found))


def cmd_scan_strings(debugger, command, result, internal_dict):
    # must be in breakpoint context or object freed
    args = command.strip().split()
    if not args:
        print("用法: wx_scan_strings <addr>")
        return
    try:
        addr = int(args[0], 16) if args[0].startswith("0x") else int(args[0])
    except ValueError:
        print("地址格式错误")
        return

    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if not process or not process.IsValid():
        print("没有 process")
        return

    _deep_scan(process, addr)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand(
        'command script add -f wechat_msg_monitor.cmd_start wx_monitor_start'
    )
    debugger.HandleCommand(
        'command script add -f wechat_msg_monitor.cmd_stop wx_monitor_stop'
    )
    debugger.HandleCommand(
        'command script add -f wechat_msg_monitor.cmd_stats wx_monitor_stats'
    )
    debugger.HandleCommand(
        'command script add -f wechat_msg_monitor.cmd_debug_on wx_monitor_debug_on'
    )
    debugger.HandleCommand(
        'command script add -f wechat_msg_monitor.cmd_debug_off wx_monitor_debug_off'
    )
    debugger.HandleCommand(
        'command script add -f wechat_msg_monitor.cmd_scan_strings wx_scan_strings'
    )
    print("[wechat_msg_monitor] 已加载。命令：")
    print("  wx_monitor_start      — 扫描特征码、下断点、开始监听")
    print("  wx_monitor_stop       — 停止监听")
    print("  wx_monitor_stats      — 查看统计")
    print("  wx_monitor_debug_on   — 打开 dump 调试模式")
    print("  wx_monitor_debug_off  — 关闭 dump 调试模式")
    print("  wx_scan_strings <addr> — 深度扫描对象里的字符串（需先 process interrupt）")

MONITOR_PY

}




do_monitor_foreground() {
    WECHAT_PID=$(pgrep -x WeChat | head -1 || true)
    if [ -z "$WECHAT_PID" ]; then
        echo "[ERROR] 微信未运行"; exit 1
    fi
    deploy_monitor_files
    INIT_FILE=$(mktemp /tmp/wx_monitor_init.XXXXXX)
    cat > "$INIT_FILE" << EOF
command script import "$MONITOR_INSTALL_DIR/wechat_msg_monitor.py"
process attach --pid $WECHAT_PID
wx_monitor_start
continue
EOF
    trap "rm -f $INIT_FILE" EXIT
    echo "[INFO] attach 微信 (pid=$WECHAT_PID)，Ctrl+C 退出"
    lldb -s "$INIT_FILE"
}

# ── 后台 daemon ──────────────────────────────────────────
MONITOR_LABEL="com.wechatintercept.monitor"
MONITOR_PLIST="$HOME/Library/LaunchAgents/${MONITOR_LABEL}.plist"
MONITOR_DAEMON="$MONITOR_INSTALL_DIR/monitor_daemon.sh"
MONITOR_LOG="/tmp/wechat_monitor_daemon.log"
MONITOR_PID="/tmp/wechat_monitor_daemon.pid"

deploy_daemon() {
    deploy_monitor_files
    cat > "$MONITOR_DAEMON" << 'DAEMON_SH'
#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY_SCRIPT="$SCRIPT_DIR/wechat_msg_monitor.py"
LOG="/tmp/wechat_monitor_daemon.log"
PID_FILE="/tmp/wechat_monitor_daemon.pid"
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
cleanup() { [ -n "${LLDB_PID:-}" ] && kill "$LLDB_PID" 2>/dev/null; rm -f "$PID_FILE"; exit 0; }
trap cleanup INT TERM EXIT
[ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null && exit 0
echo $$ > "$PID_FILE"
log "daemon start pid=$$"
LLDB_PID="" ; LAST_PID=""
while true; do
    WPID=$(pgrep -x WeChat | head -1 || true)
    if [ -z "$WPID" ]; then
        [ -n "$LLDB_PID" ] && kill "$LLDB_PID" 2>/dev/null && wait "$LLDB_PID" 2>/dev/null
        LLDB_PID="" ; LAST_PID=""
        sleep 3; continue
    fi
    if [ "$WPID" != "$LAST_PID" ] || [ -z "$LLDB_PID" ] || ! kill -0 "$LLDB_PID" 2>/dev/null; then
        [ -n "$LLDB_PID" ] && kill "$LLDB_PID" 2>/dev/null && wait "$LLDB_PID" 2>/dev/null
        log "attach wechat pid=$WPID"
        INIT=$(mktemp /tmp/wx_mon.XXXXXX)
        cat > "$INIT" << LLDBEOF
command script import "$PY_SCRIPT"
process attach --pid $WPID
wx_monitor_start
continue
LLDBEOF
        lldb -b -s "$INIT" >> "$LOG" 2>&1 &
        LLDB_PID=$!
        LAST_PID="$WPID"
        sleep 5
        rm -f "$INIT"
    fi
    sleep 5
done
DAEMON_SH
    chmod +x "$MONITOR_DAEMON"
}

do_monitor_install() {
    deploy_daemon
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$MONITOR_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${MONITOR_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${MONITOR_DAEMON}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${MONITOR_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${MONITOR_LOG}</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF
    launchctl unload "$MONITOR_PLIST" 2>/dev/null || true
    launchctl load "$MONITOR_PLIST"
    echo "[OK] 消息监听已安装（后台自动运行）"
    echo "     日志：tail -f $MONITOR_LOG"
    echo "     状态：$0 --monitor-status"
    echo "     卸载：$0 --monitor-uninstall"
}

do_monitor_uninstall() {
    [ -f "$MONITOR_PLIST" ] && launchctl unload "$MONITOR_PLIST" 2>/dev/null && rm -f "$MONITOR_PLIST"
    [ -f "$MONITOR_PID" ] && kill "$(cat "$MONITOR_PID" 2>/dev/null)" 2>/dev/null; rm -f "$MONITOR_PID"
    [ -d "$MONITOR_INSTALL_DIR" ] && rm -rf "$MONITOR_INSTALL_DIR"
    echo "[OK] 消息监听已卸载"
}

do_monitor_status() {
    [ -f "$MONITOR_PLIST" ] && echo "LaunchAgent: 已安装" || echo "LaunchAgent: 未安装"
    if [ -f "$MONITOR_PID" ] && kill -0 "$(cat "$MONITOR_PID" 2>/dev/null)" 2>/dev/null; then
        echo "daemon: 运行中 (pid=$(cat "$MONITOR_PID"))"
    else echo "daemon: 未运行"; fi
    WPID=$(pgrep -x WeChat | head -1 || true)
    [ -n "$WPID" ] && echo "微信: 运行中 (pid=$WPID)" || echo "微信: 未运行"
    [ -f /tmp/wechat_msg_cache.tsv ] && echo "缓存: $(wc -l < /tmp/wechat_msg_cache.tsv) 行" || echo "缓存: 空"
    [ -f "$MONITOR_LOG" ] && echo "" && echo "── 最近日志 ──" && tail -5 "$MONITOR_LOG"
}

# ======================== 入口 ========================
case "${1:-}" in
    --debug|-d)
        do_debug
        ;;
    --uninstall|-u)
        do_uninstall
        ;;
    --monitor)
        do_monitor_foreground
        ;;
    --monitor-install)
        do_monitor_install
        ;;
    --monitor-uninstall)
        do_monitor_uninstall
        ;;
    --monitor-status)
        do_monitor_status
        ;;
    --help|-h)
        print_banner
        echo "用法:"
        echo "  $0                     安装防撤回"
        echo "  $0 --monitor-install   安装消息监听（后台自动运行）"
        echo "  $0 --monitor-uninstall 卸载消息监听"
        echo "  $0 --monitor-status    查看监听状态"
        echo "  $0 --monitor           前台运行消息监听（调试用）"
        echo "  $0 --debug             调试模式（无 hook，允许 lldb）"
        echo "  $0 --uninstall         卸载防撤回"
        echo "  $0 --help              帮助"
        ;;
    "")
        do_install
        ;;
    *)
        echo "[ERROR] 未知参数: $1"
        echo "用法: $0 [--help]"
        exit 1
        ;;
esac
