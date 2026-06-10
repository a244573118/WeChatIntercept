# 微信 macOS 防撤回逆向工程指南

本文档记录了适配微信 4.1.9 (CFBundleVersion: 268602) 和 4.1.10 (CFBundleVersion: 268824) 防撤回功能的完整逆向过程和最终方案，供后续版本升级时参考。

---

## 一、微信 4.1.9 架构概览

### 技术栈

| 层 | 技术 | 用途 |
|---|---|---|
| 核心逻辑 `wechat.dylib` (301MB) | **C++** 为主 + 少量 ObjC | 消息收发、撤回处理等 |
| UI 层 | ObjC/AppKit | 原生 macOS 窗口 |
| 小程序 `WeChatAppEx` (346MB) | Chromium (CEF) | 小程序引擎 |
| 网络 | C++ (mmcronet = Chromium net) | HTTP/QUIC |

### 关键特征

- ObjC 类仅剩 **65 个**（对比旧版数千个）
- 代码段超过 **90MB** 均为 C++，符号全部 strip
- 核心逻辑通过 `dlopen` 在运行时加载 `Contents/Resources/wechat.dylib`
- 没有 ObjC 的 `MessageService` 类，无法使用 Method Swizzling

### 文件布局

```
WeChat.app/
├── Contents/MacOS/WeChat           # 5MB stub launcher
├── Contents/Resources/wechat.dylib # 301MB 核心逻辑 (FAT: x86_64 + arm64)
└── Contents/MacOS/WeChatAppEx.app/ # Chromium 子应用
```

---

## 二、逆向过程

### 2.1 定位 isRevokeMessage() 函数

**方法**：在 wechat.dylib 的 arm64 slice 中搜索消息类型 10002 (0x2712) 的比较模式。

```bash
# 提取 arm64 slice
lipo -thin arm64 /Applications/WeChat.app/Contents/Resources/wechat.dylib -output /tmp/wechat_arm64
```

**搜索特征**：函数比较 `[x0, #0xc] == 10002` 然后返回 bool。

```python
# 搜索: LDR W8,[X0,#0xc]; MOV W9,#0x2712; CMP W8,W9; CSET W0,EQ; RET
pattern = struct.pack('<IIIII', 0xB9400C08, 0x5284E249, 0x6B09011F, 0x1A9F17E0, 0xD65F03C0)
```

**结果**（arm64 dylib slice）：

| 项目 | 值 |
|------|------|
| 函数 VA (dylib) | `0x44E3D50` |
| Hook dispatch slot VA | `0x9301838` |
| FAT arm64 slice offset | `0x9B18000` |

**函数结构**：
```asm
0x44E3D50: adrp  x9, #0x9301000    ; 加载 hook 表页地址
0x44E3D54: ldr   x9, [x9, #0x838]  ; 加载 hook 函数指针 (slot)
0x44E3D58: cbz   x9, #0x44E3D60    ; 如果 slot 为空，跳过
0x44E3D5C: br    x9                 ; 跳转到 hook 函数
0x44E3D60: ldr   w8, [x0, #0xc]    ; 读取消息类型
0x44E3D64: mov   w9, #0x2712       ; 10002
0x44E3D68: cmp   w8, w9            ; 比较
0x44E3D6C: cset  w0, eq            ; 返回 bool
0x44E3D70: ret
```

### 2.2 微信内建 Hook Dispatch 机制

微信在每个类型检查函数开头都有一个 **hook dispatch slot** 机制：
1. 从 `__DATA` BSS 区域加载一个函数指针
2. 如果不为 NULL，跳转到该函数（允许外部 hook）
3. 如果为 NULL，执行原始逻辑

这个机制可能用于微信自己的热修复系统。我们可以利用它来安装 hook，**无需修改代码段**。

**Slot 地址**：`0x9301838`（在 `__DATA` segment 的 BSS 区域，运行时零初始化）

### 2.3 区分"自己撤回"和"对方撤回"

**问题**：简单让 `isRevokeMessage()` 返回 false 会导致自己撤回时闪退（内部状态不一致）。

**解决方法**：通过打日志逆向消息对象字段，找到区分标志。

#### 打日志方法

在 hook 函数中 dump 消息对象内存：

```objc
FILE *logFile = fopen("/tmp/wechat_revoke_debug.log", "a");
for (int offset = 0; offset <= 0x100; offset += 4) {
    int32_t val = *(int32_t *)((uint8_t *)msg + offset);
    if (val != 0 && val != (int32_t)0xAAAAAAAA) {
        fprintf(logFile, "  [+0x%02x] = %d (0x%08x)\n", offset, val, (uint32_t)val);
    }
}
```

#### 实验结果

| 场景 | `[msg+0x18]` 的值 | 含义 |
|------|-------------------|------|
| 对方撤回 | `0x64697877` ("wxid" little-endian) | 包含对方的微信 ID |
| 自己撤回（第1次调用） | `0` | 空（初始事件） |
| 自己撤回（第2次调用） | 纯数字 ID | 撤回确认的 msg ID |

#### 最终判断逻辑

```c
uint32_t field18 = *(uint32_t *)((uint8_t *)msg + 0x18);
if (field18 == 0x64697877) { // "wxid" in little-endian
    return 0; // 对方撤回 → 阻止
}
return 1; // 自己撤回 → 放行
```

### 2.4 x86_64 版本的对应地址

| 项目 | arm64 | x86_64 |
|------|-------|--------|
| isRevokeMessage VA | `0x44E3D50` | `0x4AF08D0` |
| 函数特征 | `LDR+MOV+CMP+CSET+RET` | `CMP [RDI+0xc],0x2712; SETE; RET` |
| Hook slot VA | `0x9301838` | 需重新分析（不同偏移） |

---

## 三、最终方案：DYLD 注入

### 3.1 方案架构

```
WeChat 主程序
    ↓ LC_LOAD_DYLIB (注入)
WeChatAntiRevoke.dylib
    ↓ constructor (延迟1秒)
找到 wechat.dylib 的 ASLR slide
    ↓
将 hook 函数指针写入 slot (slide + 0x9301838)
    ↓
微信调用 isRevokeMessage() 时自动跳转到 hook
```

### 3.2 注入方式

通过 Python 直接修改微信主可执行文件的 Mach-O header，在 load commands 末尾追加 `LC_LOAD_DYLIB`：

```python
# LC_LOAD_DYLIB 结构
lc_data = struct.pack('<I', 0xC)          # cmd = LC_LOAD_DYLIB
lc_data += struct.pack('<I', cmd_size)     # cmdsize
lc_data += struct.pack('<I', 24)           # name offset
lc_data += struct.pack('<I', 2)            # timestamp
lc_data += struct.pack('<I', 0x10000)      # current_version
lc_data += struct.pack('<I', 0x10000)      # compat_version
lc_data += dylib_name                      # @executable_path/../Resources/WeChatAntiRevoke.dylib
```

### 3.3 Hook 安装

利用微信自带的 dispatch slot（BSS 区域，运行时可写）：

```objc
__attribute__((constructor))
static void hook_init(void) {
    dispatch_after(1秒, ^{
        uintptr_t slide = find_wechat_slide();
        void **slot = (void **)(slide + 0x9301838);
        // BSS 区域默认 RW，直接写入
        *slot = (void *)&hook_isRevokeMessage;
    });
}
```

### 3.4 签名要求

修改后必须重签名，否则触发 `CODESIGNING - Invalid Page` 崩溃：

```bash
codesign --force --sign - WeChatAntiRevoke.dylib
codesign --force --sign - WeChat (主程序)
codesign --force --deep --sign - WeChat.app
```

---

## 四、微信 4.1.10 适配记录 (CFBundleVersion: 268824)

### 4.1 关键变化

| 项目 | 4.1.9 | 4.1.10 |
|------|-------|--------|
| arm64 isRevokeMessage VA | `0x44E3D50` | `0x44FFE20` |
| x86_64 isRevokeMessage VA | `0x4AF08D0` | `0x4B4E9A0` |
| arm64 hook dispatch slot | `0x9301838`（存在） | **已移除** |
| arm64 函数大小 | 9 条指令（36 字节）| 5 条指令（20 字节） |

### 4.2 arm64 函数结构变化

**4.1.9**（9 条，有 hook dispatch）：
```asm
0x44E3D50: adrp  x9, #0x9301000    ; 加载 hook 表页地址
0x44E3D54: ldr   x9, [x9, #0x838]  ; 加载 hook 函数指针
0x44E3D58: cbz   x9, #0x44E3D60    ; slot 为空则跳过
0x44E3D5C: br    x9                 ; 跳转到 hook
0x44E3D60: ldr   w8, [x0, #0xc]    ; 原始逻辑...
0x44E3D64: mov   w9, #0x2712
0x44E3D68: cmp   w8, w9
0x44E3D6C: cset  w0, eq
0x44E3D70: ret
```

**4.1.10**（5 条，无 dispatch，精简版）：
```asm
0x44FFE20: ldr   w8, [x0, #0xc]
0x44FFE24: mov   w9, #0x2712
0x44FFE28: cmp   w8, w9
0x44FFE2C: cset  w0, eq
0x44FFE30: ret
```

### 4.3 4.1.10 Hook 方案：Inline Trampoline

由于 dispatch slot 已移除，改为运行时覆写函数体。

**arm64 trampoline（20 字节，恰好覆盖整个函数）**：
```
offset  0: 58 00 00 50   LDR X16, #8      ; 从 PC+8 加载绝对地址
offset  4: D6 1F 02 00   BR  X16          ; 跳转
offset  8: [8 字节 hook 函数绝对地址]
offset 16: 1F 20 03 D5   NOP
```

**x86_64 trampoline（16 字节，恰好覆盖整个函数）**：
```
offset  0: FF 25 00 00 00 00   JMP QWORD PTR [RIP+0]
offset  6: [8 字节 hook 函数绝对地址]
offset 14: 90                  NOP
offset 15: C3                  RET
```

### 4.4 版本自动识别逻辑

运行时在 `hook_init` 中通过读取函数头部指令来区分版本，无需读取 `Info.plist`：

- **arm64**：读取 `slide + 0x44FFE20` 处的 4 字节
  - `== 0xB9400C08`（`LDR W8,[X0,#0xC]`）→ 4.1.10，inline trampoline
  - 其他 → 4.1.9，写入 dispatch slot `0x9301838`
- **x86_64**：先探测 4.1.10 VA，再探测 4.1.9 VA，头部均为 `55 48 89 E5`（`PUSH RBP; MOV RBP,RSP`）；匹配哪个就 patch 哪个

---

## 五、新版本适配步骤

当微信发布新版本时，按以下步骤适配：

### Step 1：提取 arm64 slice

```bash
lipo -thin arm64 /Applications/WeChat.app/Contents/Resources/wechat.dylib -output /tmp/wechat_arm64
```

### Step 2：搜索 isRevokeMessage 新地址

搜索特征模式 `LDR W8,[X0,#0xc]; MOV W9,#0x2712; CMP; CSET; RET`：

```python
pattern = struct.pack('<IIIII', 0xB9400C08, 0x5284E249, 0x6B09011F, 0x1A9F17E0, 0xD65F03C0)
idx = arm64_data.find(pattern)
```

### Step 3：确定新的 hook slot 地址

从 `isRevokeMessage` 函数开头的 `ADRP + LDR` 指令解码 slot 地址：

```python
# 读取函数前两条指令
adrp_insn = ...  # 解码得到页地址
ldr_insn = ...   # 解码得到页内偏移
slot_va = adrp_page + ldr_offset
```

### Step 4：验证区分逻辑是否仍有效

用打日志的方式验证 `+0x18` 字段是否仍然是 "wxid" 判断条件。如果新版本改变了消息对象结构，需要重新 dump 字段。

### Step 5：更新 hook.m 中的地址常量

```c
static const uintptr_t kSlotVA = 0x新地址;
```

### Step 6：测试

1. 对方撤回 → 消息保留
2. 自己撤回 → 不闪退
3. 正常收发消息 → 不受影响

---

## 六、踩过的坑

### 5.1 纯静态 patch 导致自己撤回闪退

直接 patch `isRevokeMessage()` 为 `MOV W0,#0; RET` 会导致自己撤回时崩溃。原因：
- 自己撤回后服务器回复确认（也是 type=10002）
- 如果 `isRevokeMessage` 返回 false，后续代码期望的上下文对象未被创建
- 访问 null 对象的 `+0x168` 字段 → SIGSEGV

### 5.2 `__DATA` BSS 区域不在文件中

Slot 地址在 `__DATA` segment 的 BSS 区域（`filesize < vmsize`），运行时才存在。不能通过静态修改文件来设置 slot 值，只能通过运行时内存写入。

### 5.3 代码签名验证

修改 `wechat.dylib` 后必须重签名。即使是恢复原始字节，只要之前签名过一次，哈希就已经变了。每次修改后都要：
```bash
codesign --force --sign - wechat.dylib
codesign --force --deep --sign - WeChat.app
```

### 5.4 `com.apple.provenance` 保护

从 App Store/官网下载的微信有 provenance 属性，阻止任何修改。解决：
```bash
tar --no-xattrs -cf - -C /Applications WeChat.app | tar -xf - -C /tmp/
rm -rf /Applications/WeChat.app
mv /tmp/WeChat.app /Applications/WeChat.app
```

### 5.5 wechat.dylib 是 dlopen 加载的

hook dylib 的 constructor 执行时 wechat.dylib 可能还未加载。必须用 `dispatch_after` 延迟执行。

### 5.6 macOS Sequoia `com.apple.provenance` 无法清除

macOS 15 (Sequoia) 在文件移入 `/Applications` 时会自动附加 `com.apple.provenance`，即使用 `tar --no-xattrs` 重打包也无法永久清除。

**解决方案**：签名时注入 entitlements 绕过 Library Validation：
```bash
codesign --force --sign - --entitlements ent.plist /Applications/WeChat.app/Contents/MacOS/WeChat
```
其中 `ent.plist` 包含：
- `com.apple.security.cs.disable-library-validation` = true
- `com.apple.security.cs.allow-unsigned-executable-memory` = true

### 5.7 Frameworks/wechat.dylib 是 stub，不能使用其 slide

4.1.10 中存在两个 `wechat.dylib`：
- `Contents/Frameworks/wechat.dylib`（16K stub）
- `Contents/Resources/wechat.dylib`（~147M 核心库）

两者 ASLR slide 不同。`find_wechat_slide()` 必须优先匹配 Resources 路径，否则用错误的 slide 计算函数地址会导致 hook 失败。

### 5.8 仅匹配 "wxid" 前缀无法覆盖所有用户

旧版判断逻辑 `field18 == 0x64697877` 只在对方 ID 以 "wxid_" 开头时生效。自定义微信号（如 "a244573118"）不以 "wxid" 开头，会被误判为"自己撤回"而放行。

**解决**：读取当前登录用户 ID，做完整字符串比较。

### 5.9 用户 ID 读取时机

`hook_init` 延迟 1 秒时用户可能尚未完成登录（特别是切换账号场景），此时 `app_data/login/` 目录仍指向上一个账号。

**解决**：使用懒加载，在 `hook_isRevokeMessage` 首次收到 type=0x2712 消息时才读取用户 ID。

### 5.10 在聊天界面内插入系统消息不可行

尝试过的方案：
1. **Hook `is_revoke` 标记函数 (0x4736C10)**：NOP 后消息仍然消失（删除发生在标记之前）
2. **NOP 两个 BLR 虚函数调用**：导致后续代码空指针 crash
3. **调用 `0x4D5FD70`（插入本地消息函数）**：参数是栈上复杂 C++ 结构体，需要 session 对象和消息内容对象，构造极困难
4. **数据库直接操作**：微信使用 SQLCipher 加密，无法直接 INSERT

微信撤回的真实流程：
```
isRevokeMessage=1 → BLR 虚函数（UPDATE msg_type=10002, message_content=replacemsg）→ 标记 is_revoke=1
```

**结论**：无法稳定地在聊天界面内插入提示。最终方案为 `isRevokeMessage` 返回 0（阻止撤回）+ macOS 本地通知提醒用户。

---

## 七、关键工具和命令

```bash
# 查看微信版本
defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleVersion

# 查看 FAT binary 信息
lipo -detailed_info /Applications/WeChat.app/Contents/Resources/wechat.dylib

# 查看 segment 信息
otool -arch arm64 -l /tmp/wechat_arm64

# 搜索字符串
strings /tmp/wechat_arm64 | grep -i revoke

# 反汇编（需要 capstone）
pip3 install capstone

# 编译 hook dylib
clang -arch arm64 -arch x86_64 -shared -framework Foundation -o hook.dylib hook.m

# 签名
codesign --force --deep --sign - /Applications/WeChat.app
```

---

## 八、消息对象结构（已知字段）

基于 v268602 / v268824 版本的实验结果：

| 偏移 | 类型 | 含义 |
|------|------|------|
| +0x00 | ptr | 可能是 vptr 或引用计数 |
| +0x04 | int32 | 固定为 1 |
| +0x0C | int32 | **消息主类型**（10002=撤回） |
| +0x10 | int32 | 消息子类型（用于 type=0x31 的消息） |
| +0x18 | char[] | **撤回操作发起者 ID**（std::string SSO buffer，直接存储字符内容）|
| +0x18+len+pad | char[] | 会话对方 ID |
| +0x90 | - | 未初始化标记区 |
| +0xB8 | float | 固定 1.0 (0x3F800000) |
| +0xF4 | int32 | 始终为 0（不是方向字段） |

### 区分自己/对方的关键（4.1.10 最终方案）

`[msg+0x18]` 存储的是**执行撤回操作的人的完整 ID**（C 字符串，SSO 模式直接存储）。

判断逻辑：
1. `[msg+0x18]` 为空（首字节=0）→ 自己撤回确认 → 放行
2. `[msg+0x18]` == 当前登录用户 ID → 自己撤回 → 放行
3. 其他 → 对方撤回 → 阻止

**注意**：旧方案仅判断前 4 字节是否为 "wxid"，在用户自定义微信号（非 wxid_ 开头）时失效。
必须用完整字符串匹配。

### 获取当前登录用户 ID

从以下目录读取最近修改的子目录名：
```
~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/login/
```

该目录下每个子目录名即为一个曾登录的用户 ID。按 `key_info.dat` 的修改时间排序，最新的即当前登录用户。

**关键**：必须使用懒加载（在首次收到撤回消息时才读取），避免在登录完成前读取到上一个账号。

### msg+0x18 内存布局实例

**自己撤回**（用户 ID = "a244573118"）：
```
+0x18: 61 32 34 34 35 37 33 31  31 38 00 00 00 00 00 00   a244573118......
+0x28: 00 00 00 00 00 00 00 0a  77 78 69 64 5f 6f 6f 66   ........wxid_oof
```

**对方撤回**（对方 ID = "wxid_zx0ckqw4o4u022"）：
```
+0x18: 77 78 69 64 5f 7a 78 30  63 6b 71 77 34 6f 34 75   wxid_zx0ckqw4o4u
+0x28: 30 32 32 00 00 00 00 13  61 32 34 34 35 37 33 31   022.....a2445731
```

### msg+0x130 XML body（std::string 堆分配）

撤回消息的完整 XML body 在 `msg+0x130` 处，为 `std::string` 堆分配模式：

| 偏移 | 类型 | 含义 |
|------|------|------|
| +0x130 | uint64 | 指针（指向堆上的字符串内容） |
| +0x138 | uint64 | 字符串长度 |
| +0x140 | uint64 | 容量（最高位 0x80 = 堆分配标志） |

XML 格式：
```xml
<sysmsg type="revokemsg">
  <revokemsg>
    <session>wxid_xxx</session>
    <msgid>333777384</msgid>
    <newmsgid>2651126785189248779</newmsgid>
    <replacemsg><![CDATA["用户昵称" 撤回了一条消息]]></replacemsg>
  </revokemsg>
</sysmsg>
```

**可提取信息**：
- `<replacemsg>` 中的 CDATA 内容包含**用户昵称**（非 ID）
- `<msgid>` 是被撤回的原消息 ID（但无法用于获取原消息内容，因为 DB 加密）

---

## 九、最终方案总结

### 架构

```
WeChat 主程序
    ↓ LC_LOAD_DYLIB (注入)
WeChatAntiRevoke.dylib
    ↓ constructor (延迟1秒)
    ↓ 找到 wechat.dylib slide
    ↓ 写入 inline trampoline 到 isRevokeMessage 入口
    ↓
微信调用 isRevokeMessage() 时跳转到 hook 函数
    ↓ 判断 sender ID == 自己？
    ├─ 是 → 返回 1（放行撤回）
    └─ 否 → 提取 XML replacemsg → 发通知 → 返回 0（阻止撤回）
```

### Hook 方式对比

| 版本 | 方式 | 地址 |
|------|------|------|
| 4.1.9 arm64 | BSS dispatch slot 写入 | slot VA = `0x9301838` |
| 4.1.10 arm64 | inline trampoline（20字节覆盖函数体） | func VA = `0x44FFE20` |
| 4.1.9/4.1.10 x86_64 | inline trampoline（16字节） | `0x4AF08D0` / `0x4B4E9A0` |

### 通知实现

通过 `osascript` 执行 AppleScript 发送 macOS 本地通知：
1. 从 `msg+0x130` 的 XML body 中提取 `<![CDATA[...]]>` 内容（包含用户昵称）
2. 对内容做 AppleScript 转义（英文双引号、反斜杠）
3. 写入 `/tmp/antirevoke_notify.scpt`
4. 异步执行 `osascript /tmp/antirevoke_notify.scpt`

通知开关：通过 `~/.config/antirevoke/config` 配置文件中的 `notify=0/1` 控制。

### 配置文件

路径：`~/.config/antirevoke/config`

```ini
notify=1    # 1=开启撤回通知, 0=关闭
```

### 脚本命令

```bash
./patch.sh              # 安装防撤回
./patch.sh openNotify   # 开启撤回通知
./patch.sh closeNotify  # 关闭撤回通知
./patch.sh --debug      # 调试模式（无 hook，允许 lldb attach）
./patch.sh --uninstall  # 卸载
```

---

## 十、新版本快速适配指南

当微信发布新版本时，按以下步骤适配：

### Step 1：确认版本号

```bash
defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleVersion
defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleShortVersionString
```

### Step 2：提取 arm64 slice

```bash
lipo -thin arm64 /Applications/WeChat.app/Contents/Resources/wechat.dylib -output /tmp/wechat_arm64
```

### Step 3：搜索 isRevokeMessage 新地址

```python
import struct
with open('/tmp/wechat_arm64', 'rb') as f:
    data = f.read()

# 搜索特征：LDR W8,[X0,#0xc]; MOV W9,#0x2712; CMP W8,W9; CSET W0,EQ; RET
pattern = struct.pack('<IIIII', 0xB9400C08, 0x5284E249, 0x6B09011F, 0x1A9F17E0, 0xD65F03C0)
idx = data.find(pattern)
print(f"isRevokeMessage VA: 0x{idx:X}")
```

### Step 4：确认函数结构

检查函数是否有 dispatch slot（前面有 ADRP+LDR+CBZ+BR）：
- 有 → 使用 slot 方式（记录 slot VA）
- 无 → 使用 inline trampoline 方式

### Step 5：确认 wechat.dylib 路径

检查 wechat.dylib 是在 `Contents/Resources/` 还是 `Contents/Frameworks/`，
`find_wechat_slide()` 需要优先匹配正确的路径。

### Step 6：验证消息对象结构

用 `./patch.sh --debug` + lldb 验证：
- `msg+0x0C` 仍然是 msgType 字段？
- `msg+0x18` 仍然是 sender ID（SSO 字符串）？
- `msg+0x130` 仍然是 XML body（std::string 堆分配）？

```lldb
lldb -p $(pgrep -x WeChat)
image list wechat.dylib
# slide = Resources 行地址
br set -a <slide+新函数VA> -c '(*(int*)($x0+0xc) == 0x2712)'
c
# 对方撤回后：
memory read $x0 --count 512
memory read $x0+0x130 --count 24 --format x
# 读取 XML 指针内容
```

### Step 7：验证用户 ID 获取

确认 `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/login/` 目录结构是否变化。

### Step 8：更新 patch.sh 中的地址常量

```c
static const uintptr_t k_NEW_VERSION_FuncVA_arm64  = 0x新地址;
static const uintptr_t k_NEW_VERSION_FuncVA_x86_64 = 0x新地址;
```

### Step 9：测试

1. 对方撤回 → 消息保留 + 通知弹出
2. 自己撤回 → 正常处理
3. 正常收发消息 → 不受影响

### Step 10：多设备验证

在不同用户设备上验证（特别注意）：
- macOS Sequoia 的 provenance 问题（需要 entitlements 绕过）
- `Frameworks/wechat.dylib` stub 的 slide 干扰问题
- 用户 ID 非 "wxid" 开头的兼容性

---

## 十一、自动寻址机制（应对微信动态更新）

### 11.1 背景

微信支持动态热更新（无需经过 App Store），更新后会替换 `wechat.dylib`，导致：
- 函数地址（`isRevokeMessage` 的 VA）变化
- 硬编码地址失效，hook 不生效
- 用户在不知情的情况下"防撤回功能突然不工作"

### 11.2 三级查找策略

`hook_init` 中按以下顺序查找 `isRevokeMessage` 函数：

```
1. 快速路径（硬编码地址 + 完整特征码验证）
   ↓ 失败
2. 特征码搜索（扫描整个 __TEXT 段）
   ↓ 失败
3. 4.1.9 slot fallback（仅 arm64）
   ↓ 失败
4. 弹出系统通知告知用户
```

#### 第一级：快速路径

```c
uintptr_t func_4110 = slide + k4110_FuncVA_arm64;  // 硬编码 0x44FFE20
uint32_t head_insn = *(volatile uint32_t *)func_4110;

if (head_insn == 0xB9400C08u) {
    // 进一步验证完整 5 条指令特征码（避免单指令误判）
    uint32_t *p = (uint32_t *)func_4110;
    if (p[1] == 0x5284E249u && p[2] == 0x6B09011Fu &&
        p[3] == 0x1A9F17E0u && p[4] == 0xD65F03C0u) {
        func_addr = func_4110;  // 命中，直接使用
    }
}
```

**关键点**：必须验证完整 5 条指令特征码，单看第一条 `LDR W8, [X0, #0xC]` 会误判（其他函数也可能以这条指令开头）。

#### 第二级：特征码搜索

通过 Mach-O `LC_SEGMENT_64` load command 解析 `__TEXT` 段范围（约 145MB），然后逐 4 字节扫描特征码。

**arm64 特征码**（5 条指令，20 字节）：
```
0xB9400C08  LDR W8, [X0, #0xC]
0x5284E249  MOV W9, #0x2712
0x6B09011F  CMP W8, W9
0x1A9F17E0  CSET W0, EQ
0xD65F03C0  RET
```

**x86_64 特征码**（16 字节函数体）：
```
55 48 89 E5             ; PUSH RBP; MOV RBP, RSP
81 7F 0C 12 27 00 00    ; CMP DWORD PTR [RDI+0xC], 0x2712
0F 94 C0                ; SETE AL
5D C3                   ; POP RBP; RET
```

**性能**：约 145MB / 4 = 36M 次比较，启动时一次性开销约 100-500ms。

#### 第三级：4.1.9 slot fallback

如果是 4.1.9 版本（函数有 dispatch slot 但没有完整特征码），尝试写入 `0x9301838` 的 BSS slot。

### 11.3 版本检测与失败提示

```c
// 已知支持的 build
static const char *kKnownBuilds[] = { "268602", "268824", NULL };
```

`hook_init` 启动时读取 `Info.plist` 的 `CFBundleVersion`，安装失败时根据是否在已知列表中弹出不同通知：

| 场景 | 通知文案 |
|------|---------|
| 未知 build（如 4.1.11） | `WeChatIntercept 需更新：微信版本 4.1.11 (build XXX) 未适配，防撤回功能已失效。请前往 GitHub 获取最新脚本` |
| 已知 build 但失败 | `WeChatIntercept 异常：已知版本 4.1.10 (268824) hook 安装失败，请查看 /tmp/antirevoke_debug.log` |

### 11.4 消息对象偏移失效检测

`hook_isRevokeMessage` 中增加 `is_valid_sender()` 检查 `msg+0x18` 的内容：

```c
static _Bool is_valid_sender(const char *s) {
    if (s[0] == '\0') return 1;  // 空字符串合法
    int len = 0;
    for (int i = 0; i < 32; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '\0') { len = i; break; }
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-')) {
            return 0;
        }
    }
    return (len >= 3);
}
```

若 `+0x18` 偏移失效（读到非 ASCII 数据），通知用户偏移异常 + 显示首 16 字节 hex，并保守阻止撤回。

### 11.5 测试自动寻址是否生效

#### 方案 A：模拟"地址失效"场景（验证特征码搜索）

修改 `patch.sh` 中的硬编码地址为错误值：
```c
static const uintptr_t k4110_FuncVA_arm64 = 0x4500000;  // 故意改错
```

执行 `./patch.sh` 安装后查看日志：
```bash
cat /tmp/antirevoke_debug.log
```

**预期日志**：
```
[AntiRevoke] 微信版本: 4.1.10 (build 268824) [已适配]
[AntiRevoke] slide=0x... __TEXT=[0x..., +0x...) found=1
[AntiRevoke] 快速路径未命中，开始特征码搜索...
[AntiRevoke] 特征码搜索找到: 0x... (offset 0x44FFE20)
[AntiRevoke] arm64 trampoline 安装成功
```

**验证点**：
- 看到 `快速路径未命中` 和 `特征码搜索找到`
- 找到的 offset 与原始硬编码 `0x44FFE20` 一致
- 防撤回功能仍然正常工作

测试完成后**记得恢复 `patch.sh`**。

#### 方案 B：模拟"完全失败"场景（验证失败通知）

把硬编码地址和特征码都改错：
```c
static const uintptr_t k4110_FuncVA_arm64 = 0x4500000;
// scan_isRevokeMessage_arm64 中的 pattern 第一项改为 0xDEADBEEF
```

**预期**：
- 弹出系统通知 `"WeChatIntercept 异常：已知版本 4.1.10 (268824) hook 安装失败..."`
- 防撤回不生效
- 日志显示 `ERROR: hook 安装失败`

#### 方案 C：模拟"未知 build"场景（验证更新提示）

修改 `kKnownBuilds`：
```c
static const char *kKnownBuilds[] = { "268602", NULL };  // 移除当前 build
```

同时把硬编码地址和特征码都改错。

**预期通知**：
```
WeChatIntercept 需更新
微信版本 4.1.10 (build 268824) 未适配，防撤回功能已失效。请前往 GitHub 获取最新脚本
```

#### 测试检查清单

| 检查项 | 命令 |
|--------|------|
| Hook 是否安装成功 | `cat /tmp/antirevoke_debug.log \| grep "trampoline 安装成功\|hook 安装失败"` |
| 走的哪条路径 | 日志中 `快速路径命中` / `特征码搜索找到` / `slot 写入` 关键字 |
| 微信版本读取 | 日志首行 `微信版本: x.x.x (build XXX) [已适配/未适配]` |
| 通知是否弹出 | 屏幕右上角观察 |
| 防撤回是否生效 | 让对方撤回消息，看是否保留 |

### 11.6 维护建议

当微信发布新版本：

1. **小升级（实现不变，仅地址变化）**：脚本会自动适配，无需任何操作
2. **小升级（已知版本 build 变化）**：用户提交 issue 后，将新 build 加入 `kKnownBuilds[]`
3. **大升级（实现变化，特征码失效）**：
   - 提取 arm64 slice，搜索新的特征码
   - 更新 `scan_isRevokeMessage_arm64` 中的 pattern
   - 更新硬编码地址
   - 同时验证消息对象偏移（`+0x18`、`+0x130`）是否变化

### 11.7 设计原则

1. **不依赖单一硬编码**：地址、特征码、版本号是三层独立的依赖
2. **失败要可见**：用户必须知道 hook 失效了，而不是默默地不工作
3. **保守优于激进**：偏移异常时返回 0（阻止撤回），不冒险解析未知数据
4. **去重通知**：用 `static _Bool warned` 避免通知风暴

---

## 十二、参考项目

- [WeChat-Anti-Revoke-For-Mac](https://github.com/lerry903/WeChat-Anti-Revoke-For-Mac) - 适配 v37342 (x86_64)，使用函数指针 slot 替换 + ObjC Method Swizzling
- [WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) - 旧版静态二进制 patch 方案

---

## 十三、消息原文缓存（撤回通知带原文）

### 13.1 背景

防撤回 hook 拦截撤回行为后，仅能从撤回 XML 的 CDATA 拿到 `XX 撤回了一条消息`，**拿不到被撤回消息的原文**。要在通知里显示原文，需要在消息到达时就把它存下来，撤回到来时按 ID 反查。

直接改 dylib 实现难度高（见下文 13.5），最终采用 **lldb monitor + 文件 IPC** 方案。

### 13.2 总体架构

```
┌─────────────┐     断点回调       ┌────────────────────┐
│  微信进程    │ ◄──────────────── │ lldb (后台 daemon) │
│  wechat.dylib│                    │ wechat_msg_monitor │
└─────┬───────┘                    └─────────┬──────────┘
      │ 收到消息                              │ 写
      │ 命中 257712 +20 断点                  ▼
      │                              /tmp/wechat_msg_cache.tsv
      │ 撤回到来                             ▲
      ▼                                      │ 读
┌──────────────────────┐                   │
│ WeChatAntiRevoke.dylib│ ──────────────────┘
│ hook_isRevokeMessage  │
└──────────────────────┘
       │ 拼通知
       ▼
   macOS 通知中心
```

### 13.3 消息对象（CMessageWrap）字段布局

通过 lldb 实测验证（4.1.10），消息对象关键字段：

| 偏移 | 字段 | 类型 | 说明 |
|------|------|------|------|
| `+0x00` | vtable | ptr | C++ 虚函数表 |
| `+0x08` | FromWrapper | ptr | 包装对象，wrapper+0x08 → wxid 字符串 |
| `+0x10` | subtype vtable | ptr | 消息类型标识 |
| `+0x40` | ContentWrapper | ptr | 包装对象，wrapper+0x00 → 展示文本字符串 |
| `+0x48` | CreateTime | int32 | Unix 时间戳 |
| `+0x4c` | MsgLocalID | int32 | 本地消息 ID |
| `+0x50` | MsgSvrID | int64 | **服务器消息 ID（撤回 XML 里的 newmsgid）** |
| `+0x70` | （某字段） | int64 | 257712 函数会读取此处写入返回值对象 |

**展示文本格式**：
- 文本：`<昵称> : <正文>`（私聊群聊都是这格式）
- 图片/视频/文件：`<昵称>在群聊中发了一张图片` 等描述模板

### 13.4 Hook 点：unnamed_symbol257712

通过分析 `isRevokeMessage` 的调用栈（见 §2.1），在 `frame #4` 找到 CMessageWrap 的某个虚方法 `unnamed_symbol257712`：

```
+0x00:  stp x20,x19,[sp,#-0x20]!     a9be4ff4   ; prologue
+0x04:  stp x29,x30,[sp,#0x10]       a9017bfd
+0x08:  add x29,sp,#0x10             910043fd
+0x0c:  mov x19,x1                   aa0103f3   ; x19 = msg
+0x10:  bl  257706                   <相对>      ; 调用 257706 处理消息
+0x14:  ldr x8,[x19,#0x70]           f9403a68   ; 读 msg+0x70
+0x18:  str x8,[x0,#0x100]           ...        ; 写返回值+0x100
+0x1c:  epilogue
+0x24:  ret
```

**关键观察**：
- `+0x10` 处的 `bl 257706` **必须先执行**，因为它会填充 msg 对象内的字段（包括 +0x40 的 content 指针）
- `+0x14` 时 x19 仍持有 msg 指针（callee-saved），content 字段已就绪

**断点位置选择**：函数入口 + 20 字节（即 `+0x14`，`ldr` 指令处），保证 content 已填充。

### 13.5 失败方案：dylib 内 trampoline

最初尝试用 inline trampoline 在 dylib 内 hook 257712，**失败**：

```c
void *hook_msgWrap_257712(void *out_obj, void *msg) {
    void *new_x0 = g_orig_257706(msg);   // ← 这里崩溃
    *(uint64_t*)(new_x0 + 0x100) = *(uint64_t*)(msg + 0x70);
    cache_put(...);
    return new_x0;
}
```

崩溃栈：
```
0  libc++  std::basic_string::operator=  FAR=0x17
1  wechat.dylib +76121620
2  WeChatAntiRevoke.dylib hook_msgWrap_257712 + 84
```

**原因**：257706 是 C++ 方法，对调用方栈帧布局有特殊假设（可能通过 `[fp, #-X]` 访问调用方局部变量）。我们的 C hook 函数 prologue 是 clang 自动生成，栈帧不一致，257706 内部读取局部变量时崩溃。

要修复需要写 naked-asm trampoline 完整保留原函数语义，复杂度高。改用 lldb monitor 方案。

### 13.6 lldb monitor 寻址

完全自动寻址，**无任何硬编码地址**：

1. **定位 wechat.dylib**：用 lldb SBTarget API 查模块，**优先选 `/Resources/wechat.dylib`**（核心库 ~140MB），过滤掉 `/Frameworks/wechat.dylib`（stub ~16KB）

2. **特征码扫描**：在 `__TEXT` 段顺序扫描，匹配模式：
   ```
   PREFIX (16字节)：f44fbea9 fd7b01a9 fd430091 f30301aa
   GAP    ( 4字节)：通配（bl 相对跳转，ASLR 后字节会变）
   SUFFIX ( 4字节)：683a40f9
   ```
   实测在 75MB __TEXT 中：PREFIX 命中 4058 次，配合 SUFFIX 校验后唯一确定 1 处。

3. **断点位置**：函数入口 + 20

4. **字段读取**：从 x19 寄存器（callee-saved，hook 时机已是 `mov x19, x1` 之后）取消息对象指针。

### 13.7 文件 IPC 协议

**路径**：`/tmp/wechat_msg_cache.tsv`

**行格式**：
```
<svrid_decimal>\t<from>\t<content>\n
```

**字段清洗**：
- `\t \n \r` 替换为空格
- content 剥掉发言人前缀（找首个 ` : ` 截左侧）
- 限制 from ≤ 63 字节，content ≤ 511 字节

**写端**（`monitor/wechat_msg_monitor.py`）：
- 内存中保留最近 500 行
- 每次更新整体重写：先写 `*.tmp`，再 `os.replace()` → 原子替换
- 写频率 = 收消息频率（频繁但每次 < 50KB I/O）

**读端**（dylib `hook_isRevokeMessage`）：
- 从撤回 XML 抽 `<newmsgid>`
- `fopen` + `fgets` 顺序扫描整个文件
- 命中后**继续扫到末尾**取最后一次写入（兼容覆盖更新）
- 频率极低（仅撤回时），无需 mmap/索引优化

### 13.8 通知文案处理

dylib 端两步处理：

1. **昵称提取**：从 XML CDATA `"Macanzy" 撤回了一条消息` 抽出纯昵称
   - 找 `撤回了` 截左侧
   - 去前后空格
   - 剥两端英文双引号（微信会给昵称加引号）

2. **消息类型识别**：缓存里的非文本消息内容是描述模板（`XX在群聊中发了一张图片`），用 `strstr` 匹配关键短语转占位符：

   | 模板片段 | 占位符 |
   |---------|--------|
   | `发了一张图片` | `[图片]` |
   | `发了一段视频` | `[视频]` |
   | `发了一个文件` | `[文件]` |
   | `发了一段语音` / `发了一条语音消息` | `[语音]` |
   | `发了一个表情` | `[表情]` |
   | `发了一个视频号` | `[视频号]` |
   | `发了一张名片` | `[名片]` |
   | `发了一个位置` | `[位置]` |
   | `发了一个红包` | `[红包]` |
   | `发了一个链接` | `[链接]` |
   | `发了一个小程序` | `[小程序]` |

3. **最终文案**：
   - 命中：`拦截到「Macanzy」撤回了一条消息：你好`
   - 未命中：`拦截到「Macanzy」撤回了一条消息`

### 13.9 LaunchAgent 守护

**daemon 脚本**：`monitor/monitor_daemon.sh`
- while 循环每 5 秒检查微信进程
- 微信启动 → 后台 `lldb -b` attach + 加载 Python 脚本
- 微信退出 → kill lldb，等待
- 微信重启 → 重新 attach

**部署位置**：必须放在 TCC 安全位置
- ✅ `~/.local/share/wechatintercept/`
- ❌ `~/Desktop/`（launchd 拉起的进程读 Desktop 会得到 `Operation not permitted`）

**LaunchAgent plist 关键项**：
```xml
<key>RunAtLoad</key><true/>          <!-- 登录后立即拉起 -->
<key>KeepAlive</key><true/>          <!-- 异常退出自动重启 -->
<key>ThrottleInterval</key><integer>10</integer>  <!-- 重启间隔 ≥10s 防 CPU 占满 -->
```

### 13.10 entitlements 要求

为让 lldb 能 attach 微信，签名时必须带 `get-task-allow`：

```xml
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.get-task-allow</key><true/>   <!-- 新增 -->
```

`patch.sh` 的正常签名流程已自动包含这一项。

### 13.11 维护建议

monitor 失效时：
1. **特征码搜不到**：4.1.x 微信改了 257712 的实现 → 用 lldb 重新反汇编 → 更新 `wechat_msg_monitor.py` 第 32-33 行的 PATTERN
2. **拿到 content 但是乱码**：消息对象偏移变了 → 用 `wx_monitor_debug_on` + `wx_scan_strings <addr>` 重新探测 +0x40 / +0x08
3. **lldb attach 失败**：检查 `codesign -d --entitlements - $WECHAT_BIN` 是否有 `get-task-allow`

### 13.12 设计原则

1. **monitor 是可选增强**：缓存不存在时通知降级为旧文案，防撤回主功能不受影响
2. **进程隔离**：lldb 异常崩溃只影响 monitor，不影响微信运行
3. **数据生命周期**：`/tmp` 重启清空，符合"消息缓存只对当次会话有意义"的语义
4. **零硬编码**：版本兼容性靠特征码，不靠地址表

### 13.13 单文件整合

最终交付物仅 `patch.sh` 一个脚本（+ README.md 文档）。

monitor 相关的三个脚本（`wechat_msg_monitor.py`、`monitor_daemon.sh`）以 heredoc 形式内嵌在 `patch.sh` 中：

```bash
deploy_monitor_files() {
    mkdir -p "$MONITOR_INSTALL_DIR"
    cat > "$MONITOR_INSTALL_DIR/wechat_msg_monitor.py" << 'MONITOR_PY'
    ...内嵌 Python 源码...
    MONITOR_PY
    cat > "$MONITOR_INSTALL_DIR/monitor_daemon.sh" << 'MONITOR_DAEMON'
    ...内嵌 daemon 脚本...
    MONITOR_DAEMON
}
```

运行 `./patch.sh --monitor-install` 时：
1. 调用 `deploy_monitor_files()` 释放脚本到 `~/.local/share/wechatintercept/`（TCC 安全路径）
2. 写 LaunchAgent plist 到 `~/Library/LaunchAgents/`
3. `launchctl load` 注册

命令列表：

| 命令 | 作用 |
|------|------|
| `./patch.sh` | 安装防撤回 |
| `./patch.sh --monitor-install` | 安装消息监听（撤回原文） |
| `./patch.sh --monitor-uninstall` | 卸载消息监听 |
| `./patch.sh --monitor-status` | 查看 daemon 状态 |
| `./patch.sh --monitor` | 前台运行（调试用） |
| `./patch.sh --uninstall` | 卸载防撤回 |

好处：
- 用户只需拿到一个文件
- 不存在"文件相对路径找不到"的问题
- `--monitor-install` 后再改源码需要重新 `--monitor-install` 才生效（等效于 make install）

### 13.14 +0x40 双重解引用（最终方案）

最终确认的 content 读取路径（4.1.10，a244573118 账号登录）：

```
msg_obj + 0x40 → ptr（8字节指针值）
ptr → std::string 结构体（24字节）：[data_ptr][size][cap|flag]
data_ptr → 实际 UTF-8 文本（"昵称 : 正文" 格式）
```

**不是之前以为的 "wrapper 对象 +0x00"**，而是**指向 std::string 结构体本身**。

std::string 布局（libc++ arm64）：
- 长字符串：`data_ptr > 0x1_0000_0000` 且 `size > 0 < 4096` → 从 data_ptr 读 size 字节
- SSO 短字符串：`data_ptr < 0x1_0000_0000`（不像指针）→ 前 22 字节就是数据，找 `\0` 截断

### 13.15 路径 B 问题（部分群聊不覆盖）

测试发现**同一版本（4.1.10）不同群**的消息走不同代码路径：

| 群 | flag2 | +0x40 指向 | content |
|---|---|---|---|
| `44001654746@chatroom` | 1 | 堆上 std::string（有内容） | ✅ |
| `wxid_oofpkofuv87f12` (私聊) | 1 | 堆上 std::string（有内容） | ✅ |
| `34757577531@chatroom` | 1 | BSS 段全局空 string（dp=0, sz=0） | ❌ |
| `45680706775@chatroom` | 2 | 代码段地址（非堆） | ❌ |

路径 B 特征：
- `ptr40 = 0x123xxxxxxx`（BSS/DATA 段地址，不是堆 `0x4xxxxxxxx` 或 `0x0axxxxxxxx`）
- std::string 内容永远为空（dp=0, sz=0）
- 三层指针扫描（0x400 字节 + 每指针下钻 0x100）也找不到正文
- 手动在 257712 入口下断点**命中不了**——说明这些群的消息**不经过 257712 函数**

结论：257712 只被**部分消息处理路径**调用。路径 B 的消息虽然 monitor 能看到（因为断点还是命中了——可能是另一条无关消息触发的），但其对象内不含 content。

**后续方向**（未实施）：
1. 找一个所有消息都必经的更上层函数
2. 或者 hook 数据库写入点（所有消息最终入库时 content 一定已就绪）
3. 或者用 naked-asm trampoline 在 dylib 内 hook，避免 lldb batch 模式时序问题

### 13.16 最终交付状态

| 功能 | 覆盖率 | 说明 |
|------|--------|------|
| 防撤回（对方撤回保留可见） | 100% | inline trampoline + 特征码自动寻址 |
| 撤回通知 | 100% | 始终弹出 |
| 通知带消息原文 | ~70% | 私聊 + 部分群聊；依赖 `--monitor` 前台运行 |
| 通知不带原文（降级） | 剩余 ~30% | 部分群聊路径 B + monitor 未运行时 |
