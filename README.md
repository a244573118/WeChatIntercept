# WeChatIntercept

macOS 微信防撤回工具。

## 最新版本

**支持微信 4.1.9 ~ 4.1.10**，适配微信全新 C++ 架构，通过 DYLD 运行时注入实现防撤回。

### 功能

- 对方撤回的消息保留可见
- 自己撤回正常工作
- 撤回时弹出 macOS 系统通知（显示谁撤回了消息）
- 通知开关可随时切换

### 原理

通过注入运行时 hook 动态库（`WeChatAntiRevoke.dylib`），拦截微信内部的 `isRevokeMessage()` 函数：

- 对方撤回 → 返回 false（消息保留）+ 弹出通知
- 自己撤回 → 返回 true（正常处理）

通过读取当前登录用户 ID（完整字符串匹配），精确区分自己与对方。

### 适用范围

- macOS 微信 4.1.9、4.1.10
- Apple Silicon（arm64）及 Intel（x86_64）
- macOS Sequoia / Sonoma / Ventura 等（自动处理 provenance 限制）

### 使用

```bash
chmod +x patch.sh         # 添加可执行权限
./patch.sh                # 安装防撤回
./patch.sh openNotify     # 开启撤回通知
./patch.sh closeNotify    # 关闭撤回通知
./patch.sh --uninstall    # 卸载
./patch.sh --help         # 帮助
```

首次运行可能需要约 30 秒（自动解除系统文件保护并重签名）。

### 配置

配置文件路径：`~/.config/antirevoke/config`

```ini
notify=1    # 1=开启撤回通知, 0=关闭
```

安装时默认开启通知，也可通过命令随时切换：

```bash
./patch.sh openNotify     # 等同于设置 notify=1
./patch.sh closeNotify    # 等同于设置 notify=0
```

修改后立即生效，无需重启微信。

### 依赖

macOS 系统自带工具，无需额外安装：
- clang（Xcode Command Line Tools）
- python3
- codesign
- tar

如未安装 Xcode Command Line Tools，运行：`xcode-select --install`

### 调试

```bash
./patch.sh --debug        # 调试模式（不安装 hook，仅签名允许 lldb attach）
cat /tmp/antirevoke_debug.log   # 查看运行时日志
```

### 已知限制

- **聊天框内无撤回提示**：由于微信 4.x 的架构限制（C++ 实现 + 符号 strip + 数据库加密），无法在聊天界面内插入系统消息。替代方案为 macOS 系统通知。

- **为什么不能像旧版那样在聊天框内显示提示？**

  旧版微信 macOS（3.x）使用 Objective-C，可通过 Method Swizzling 调用内部消息插入 API。4.x 版本核心逻辑全部迁移到 C++（仅剩 65 个 ObjC 类，90MB+ 代码段，符号已 strip），撤回处理通过虚函数 + 加密数据库 + 协程调度完成，无法稳定地从外部构造调用链插入消息。

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

### 常见问题

1. **无法打开 "insert_dylib"，因为无法验证开发者**

   在系统安全性与隐私处点击允许。

2. **截屏无法使用，已添加屏幕录制权限仍不行**

   在系统安全性与隐私中删除微信，重新添加，重启微信即可。（感谢 [Kylelkh](https://github.com/Kylelkh)）

3. **M1 芯片怎么使用**

   安装 Rosetta，在微信属性中勾选"使用 Rosetta 打开"。（感谢 [Mercury2699](https://github.com/Mercury2699)、[bolosea](https://github.com/bolosea)）

---

## 注意

- 微信更新后需重新运行 `./patch.sh`
- 仅供学习研究用途
