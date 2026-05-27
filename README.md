# WeChatIntercept
macOS 微信防撤回工具。

## 最新版本（v4.1.9）

**支持微信 4.1.9**，适配微信全新 C++ 架构，通过 DYLD 运行时注入实现防撤回，一键生效。

### 原理

通过注入一个运行时 hook 动态库（`WeChatAntiRevoke.dylib`），利用微信内建的 hook dispatch slot 机制拦截 `isRevokeMessage()` 函数。在运行时区分消息来源：
- 对方撤回 → 返回 false（消息保留不被删除）
- 自己撤回 → 返回 true（正常处理，不会闪退）

### 适用范围

- macOS 微信 4.1.9（CFBundleVersion: 268602）
- Apple Silicon（arm64）及 Intel（x86_64）

### 使用

```bash
chmod +x patch.sh       # 添加可执行权限
./patch.sh              # 安装防撤回
./patch.sh --uninstall  # 卸载
./patch.sh --help       # 帮助
```

首次运行可能需要约 30 秒（自动解除系统文件保护）。

### 依赖

macOS 系统自带工具，无需额外安装：
- clang（Xcode Command Line Tools）
- python3
- codesign
- tar
如未安装 Xcode Command Line Tools，运行：xcode-select --install

### 已知限制

- **无撤回提示**：当前方案仅静默保留原消息，不会在聊天窗口中显示"对方撤回了一条消息"的提示。你不会知道对方曾经尝试撤回，只能注意到消息没有消失。

- **为什么不能像旧版那样在聊天框内显示提示？**

  旧版微信 macOS（3.x）使用 Objective-C 构建，核心逻辑暴露为 ObjC 方法，可以通过 Method Swizzling 在运行时拦截撤回处理函数，保留原消息的同时调用微信内部的消息插入 API 写入一条提示。

  当前版本（4.1.9）的底层架构已完全不同：核心逻辑迁移到 C++ 实现（仅剩 65 个 ObjC 类，而代码段超过 90MB 均为 C++ 且符号已 strip）。撤回处理不再是独立的"删除旧消息"+"插入提示"两步操作，而是将整个消息对象替换为新的视图模型。在纯二进制补丁方式下，无法构造复杂的函数调用链来插入一条新消息到聊天记录中。

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

- 微信更新后需重新运行对应版本的补丁
- 仅供学习研究用途
