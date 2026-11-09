# 微信 4.1.13 (build 269602) 适配说明

本分支针对 macOS 微信 4.1.13 做了适配与若干修复，实测于 macOS 15.7.3 (arm64)。

## 一、4.1.13 二进制实证

在 `wechat.dylib`（342,999,376 字节，符号已 strip）上逆向确认：

| 项目 | 4.1.13 实测值 |
|---|---|
| `isRevokeMessage` 入口 | `0x4661f5c`（特征码 5 条指令正好 20 字节，下一函数在 `0x4661f70`） |
| 调用点 | `0x262b86c`、`0x262de0c`、`0x2e83848` |
| x86_64 特征码命中 | `0x4d6e940`（首字节 `0x55`，已是函数头） |
| `CMessageWrap` 构造函数 | `0x48df084` |
| 发送者 wxid 字段 | `+0x18` |
| MsgType 字段 | `+0x0C` |

特征码为 5 条指令的**完整序列**（`0xB9400C08, 0x5284E249, 0x6B09011F, 0x1A9F17E0, 0xD65F03C0`），
命中地址**即函数入口**，不需要做 `-4` 回退。

## 二、关键发现：`+0x220` 在 hook 点为空

原文逻辑假定撤回 XML 位于 `msg+0x220`（ptr）/ `+0x228`（len），但实测在
`isRevokeMessage` 被调用时 **该字段恒为 0**：

```
DIAG +0x220 = 0 | +0x228 = 0
```

原因是微信的调用顺序：

```asm
262b86c: bl   0x4661f5c        ; isRevokeMessage(msg)
262b870: cbz  w0, 跳过
262b874: ldr  x0, [x20, #0x220]  ; 确认是撤回【之后】才读该字段
```

即 `+0x220` 是在判断通过后由后续流程填充的，所以在 hook 点读不到撤回 XML。

**结论**：在 `isRevokeMessage` 上无法获取撤回 XML、原文内容或撤回者昵称。
本分支因此移除了相关读取代码（原实现会解引用未填充指针）。

## 三、通知实现的三次修正

macOS 15 上让通知真正弹出，踩了三个坑：

### 1. `osascript display notification` 无效

通知归属会变成 `com.apple.scripteditor2`（Script Editor），而该 App 从未获得通知授权，
通知被 `usernoted` **静默丢弃**，`record` 表里不会留下任何记录。

```bash
osascript -e 'display notification "test" with title "T"'
# exit=0，但通知不出现，也不留记录
```

### 2. `NSUserNotification` 已废弃

请求能进管道（日志可见 `Added notification request: hasError: 0`），但随即被清除，
不会出现在通知中心。

### 3. `performSelector` 参数上限

`requestWithIdentifier:content:trigger:` 是三参数方法，
`performSelector:withObject:withObject:withObject:` **不存在**，会抛
`unrecognized selector`。必须用 IMP 强转：

```objc
typedef id (*ReqFn)(id, SEL, id, id, id);
ReqFn reqFn = (ReqFn)[reqCls methodForSelector:sel];
id req = reqFn(reqCls, sel, ident, content, nil);
```

方法签名（`typeEncoding = @40@0:8@16@24@32`）确认 5 个参数，
与上述强转完全匹配。

### 最终方案

进程内调用 `UNUserNotificationCenter`，通知归属为微信自己
（`com.tencent.xinwechat`，通知权限用户已授权为 `auth = 7`）。
需在编译时链接 `UserNotifications.framework`，否则类查不到：

```bash
clang -arch arm64 -arch x86_64 -shared \
  -framework Foundation -framework UserNotifications ...
```

## 四、安装流程的权限修复

原脚本在 `/Applications`（`root:wheel`）上直接写入，多处会 `Permission denied`：

| 问题 | 原实现 | 修复 |
|---|---|---|
| 重建 App | `tar` → `rm -rf` → `mv`，无 sudo 且中断会**删掉 App** | 改为只清 xattr |
| 编译产物 | 直接写 `Resources/`（root 属主） | 先编到 `/tmp`，成功后提权落位 |
| 注入 | 直接改 `MacOS/WeChat` | 在 `/tmp` 副本注入，再提权替换 |
| 签名 | 三处 `codesign` 无提权 | 生成提权脚本一次性完成 |
| sudo | 多处分别询问 | 开头 `sudo -v` 一次 + 后台保活 |

## 五、当前能力边界

| 功能 | 状态 | 说明 |
|---|---|---|
| 阻止撤回、消息保留 | ✅ | |
| 系统通知提醒 | ✅ | 归属微信，可正常显示 |
| 显示发送者昵称 | ❌ | 只有 wxid，昵称不在 `CMessageWrap` 内；已过滤内部 ID 回落为「对方」 |
| 显示撤回原文 | ❌ | 见下节 |

### 显示名处理

`+0x18` 只有 wxid 这类内部 ID，无法直接展示。实现中通过
`looks_like_internal_id()` 过滤 `wxid_` / `gh_` / `*@chatroom` 前缀，
过滤后回落到「对方」，避免通知里出现 `wxid_19tplkccvpa022` 这样的长串。

该函数接受 `primary` / `secondary` / `fallback` 三级候选，为将来接入
联系人表查询预留了扩展点。

### 为什么拿不到原文

1. **撤回 XML 不含原文** — 只有 `<newmsgid>` 指向被撤回消息
2. **本地数据库加密** — `message_0.db` 为 SQLCipher，密钥在进程内存
3. **monitor 方案失效** — 内置 monitor 的特征码在 4.1.13 命中的是
   `0x48df058`（一个 20 字节的 setter），非消息处理函数，断点无法命中真实消息流

如需原文，需定位真正处理 `MsgType=10002` 的消息分发函数（非判断函数），
在 `+0x220` 已填充的位置 hook，并配合可用的消息缓存。

## 六、已验证的环境

- macOS 15.7.3 (24G419)，arm64 Apple Silicon，SIP enabled
- 微信 4.1.13 / build 269602，`com.tencent.xinWeChat`
- `clang` + `codesign` + `python3`（系统自带）
