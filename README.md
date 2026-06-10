# WeChatIntercept

macOS 微信防撤回工具，持续更新，欢迎共建和 star。

## 最新版本

**支持微信 4.1.x 系列**，适配微信全新 C++ 架构，通过 DYLD 运行时注入实现防撤回。内置**特征码自动寻址**机制，应对微信动态更新。

### 功能

- **对方撤回的消息保留可见**，弹出 macOS 系统通知告诉你撤回的消息内容：
  - 文本消息：`拦截到「张三」撤回了一条消息：你好`
  - 非文本：`拦截到「张三」撤回了一条消息：[图片] / [视频] / [文件] / [语音] / [红包] / ...`
  - 拿不到原文时降级为：`拦截到「张三」撤回了一条消息`
- 微信动态更新后自动适配（特征码搜索）

### 适用范围

- macOS 微信 4.1.x 系列（4.1.9 / 4.1.10 已验证，更新版本依赖运行时自动寻址）
- Apple Silicon（arm64）及 Intel（x86_64）
- macOS Sequoia / Sonoma / Ventura / Tahoe 等

### 依赖

macOS 系统自带工具，无需额外安装：

- clang（Xcode Command Line Tools）
- python3
- codesign
- lldb（仅消息原文功能需要；Xcode CLT 自带）

如未安装 Xcode Command Line Tools，运行：`xcode-select --install`

---

## 使用

### 基础安装（防撤回）

```bash
chmod +x patch.sh         # 添加可执行权限
./patch.sh                # 安装防撤回
./patch.sh --uninstall    # 卸载防撤回
./patch.sh --help         # 查看所有命令
```

首次运行可能需要约 30 秒（自动解除系统文件保护并重签名）。

### 可选：启用"撤回通知带原文"

完成基础安装后，安装消息监听服务，撤回通知就会带上原文（当前只支持私聊，群聊暂不支持）。

```bash
./patch.sh --monitor-install    # 安装（后台自动运行，开机自启）
./patch.sh --monitor-status     # 查看状态
./patch.sh --monitor-uninstall  # 卸载
```

安装后无需手动操作。微信启动时自动开始监听消息、微信关闭后自动收尾、下次启动再次跟随。

不安装也不影响防撤回主功能，撤回通知降级为不带原文。

> **已知限制**：部分群聊消息因内部对象结构差异，可能无法缓存原文，撤回时会降级为不带原文的通知。私聊消息和大部分群聊消息可正常获取原文。

> **注意**：需要给脚本编辑器打开通知权限！  
> <img width="912" height="108" alt="image" src="https://github.com/user-attachments/assets/5865c263-7511-4b58-92a0-e69edba54f3d" />

### 调试模式（仅开发用）

```bash
./patch.sh --debug             # 不装 hook，仅签名允许 lldb attach
./patch.sh --monitor           # 前台运行消息监听（调试用，Ctrl+C 退出）
cat /tmp/antirevoke_debug.log  # 防撤回日志
cat /tmp/wechat_monitor_daemon.log  # 监听 daemon 日志
cat /tmp/wechat_msg_cache.tsv  # 消息缓存
```

---

### 排查步骤

如果防撤回功能不生效：

1. 查看运行时日志：`cat /tmp/antirevoke_debug.log`
2. 关键日志：
   - `[已适配]` / `[未适配]` — build 号识别情况
   - `快速路径命中` / `特征码搜索找到` — hook 安装路径
   - `hook 安装失败` — 需要更新脚本，请前往 GitHub 检查最新版本或提交 issue
3. 提交 issue 时附带：
   - 微信版本：`defaults read /Applications/WeChat.app/Contents/Info.plist CFBundleShortVersionString` 与 `CFBundleVersion`
   - 调试日志：`/tmp/antirevoke_debug.log`

---

## 已知限制

- **聊天框内无撤回提示**：由于微信 4.x 的架构限制（C++ 实现 + 符号 strip + 数据库加密），无法在聊天界面内插入系统消息。替代方案为 macOS 系统通知。

- **撤回通知原文需 monitor 服务运行**：通过 `./patch.sh --monitor-install` 安装后自动后台运行。未安装时撤回通知降级为不带原文。

- **monitor 运行时微信会被 lldb attach**：性能影响极小（每条消息触发约 1ms 断点回调）。如果不需要原文功能，不安装 monitor 即可。

---

## 旧版本

支持微信 3.7.0 及更早版本，基于 DYLD 注入 + Method Swizzling，支持撤回提示和自定义前缀。

### 功能

1. 防撤回（支持聊天框内拦截提示）
2. 免认证登录
3. 拦截提示语自定义前缀

<img width="301" alt="image" src="https://user-images.githubusercontent.com/18585610/159691061-3f24b69f-a494-4549-a530-7724b1b40060.png">

### 微信 v3.7.0 下载

[微信 v3.7.0 版本](https://dldir1.qq.com/weixin/mac/WeChatMac.dmg)

### 使用方法

- **安装**：cd 到 WeChatIntercept 文件夹，将 `Install.sh` 拖到终端，输入密码回车，重启微信。
- **卸载**：将 `Uninstall.sh` 拖到终端回车。
- **自定义前缀**：安装成功后重启微信，屏幕左上角微信菜单栏有个小助手菜单，修改后点击关闭即可。

---

## 常见问题

1. **无法打开 "insert_dylib"，因为无法验证开发者**

   在系统安全性与隐私处点击允许。

2. **截屏无法使用，已添加屏幕录制权限仍不行**

   在系统安全性与隐私中删除微信，重新添加，重启微信即可。（感谢 [Kylelkh](https://github.com/Kylelkh)）

3. **M1 芯片怎么使用**

   安装 Rosetta，在微信属性中勾选"使用 Rosetta 打开"。（感谢 [Mercury2699](https://github.com/Mercury2699)、[bolosea](https://github.com/bolosea)）

4. **微信版本号没变，但防撤回失效**

   微信存在动态更新机制，版本号不变，但方法地址会有变化，重新运行`./patch.sh`即可

## 风险说明

1. 微信每次升级后，地址、结构体字段、运行时行为都可能变化，补丁可能立即失效。脚本内置特征码自动寻址机制可应对函数地址变化，但无法应对函数实现/消息对象结构的根本变化。

2. 本项目仅承诺仓库内标明的已验证版本（4.1.9 / 4.1.10）；4.1.x 系列其他 build 号通过运行时自动寻址尽力支持，但不保证 100% 兼容。

3. 本项目仅用于技术研究与兼容性分析，请自行承担使用风险。
