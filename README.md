# WeChatIntercept

macOS 微信防撤回工具，支持微信 4.1.x 系列，欢迎共建和 star。

---

## 功能

| 功能     | 说明                                                                     |
| -------- | ------------------------------------------------------------------------ |
| 防撤回   | 对方撤回的消息保留可见，自己撤回正常工作                                 |
| 撤回通知 | 弹出 macOS 系统通知，显示谁撤回了什么内容                                |
| 消息原文 | 通知中展示被撤回的原始消息（消息内容文本 / [图片] / [视频] / [文件] 等） |
| 自动适配 | 内置特征码搜索，微信小版本更新后无需手动操作                             |

通知效果：

- `拦截到「张三」撤回了一条消息：你好`
- `拦截到「张三」撤回了一条消息：[图片]`
- 拿不到原文时降级：`拦截到「张三」撤回了一条消息`

---

## 快速开始

```bash
# 1. 安装防撤回（必须）
chmod +x patch.sh
./patch.sh

# 2. 安装消息监听（可选，撤回通知带原文）
./patch.sh --monitor-install
```

完成。微信会自动重启，之后对方撤回消息时你会收到系统通知。

---

## 命令一览

| 命令                             | 作用                                   |
| -------------------------------- | -------------------------------------- |
| `./patch.sh`                     | 安装防撤回                             |
| `./patch.sh --monitor-install`   | 安装消息监听（后台自动运行，开机自启） |
| `./patch.sh --monitor-status`    | 查看监听状态                           |
| `./patch.sh --monitor-uninstall` | 卸载消息监听                           |
| `./patch.sh --uninstall`         | 卸载防撤回                             |
| `./patch.sh --help`              | 查看帮助                               |

---

## 适用范围

- macOS 微信 4.1.x（4.1.9 / 4.1.10 已验证）
- Apple Silicon（arm64）+ Intel（x86_64）
- macOS Sequoia / Sonoma / Ventura / Tahoe

---

## 依赖

macOS 系统自带，无需额外安装：

- clang / python3 / codesign / lldb（Xcode Command Line Tools）

如未安装：`xcode-select --install`

---

## 注意事项

1. **首次运行**约需 30 秒（解除系统文件保护 + 重签名）
2. **通知权限**：需给「脚本编辑器」开启通知权限，否则看不到弹窗  
   <img width="912" height="108" alt="image" src="https://github.com/user-attachments/assets/5865c263-7511-4b58-92a0-e69edba54f3d" />
3. **微信动态更新**：微信存在动态更新机制，版本号不变，但方法地址会变，重新运行`./patch.sh`即可，脚本会自动寻址
4. **消息原文覆盖率**：私聊 + 大部分群聊可正常获取；部分群聊因对象结构差异会降级为不带原文（后续优化）

---

## 排查

防撤回不生效时：

```bash
cat /tmp/antirevoke_debug.log         # 查看 hook 安装日志
cat /tmp/wechat_monitor_daemon.log    # 查看消息监听日志
./patch.sh --monitor-status           # 查看监听状态
```

关键日志含义：

- `快速路径命中` / `特征码搜索找到` → hook 安装成功
- `hook 安装失败` → 微信版本变化较大，需更新脚本

提交 issue 时请附带微信版本和日志文件。

---

## 卸载

```bash
./patch.sh --monitor-uninstall   # 卸载消息监听（如安装过）
./patch.sh --uninstall           # 卸载防撤回，恢复原始微信
```

---

## 调试（开发者）

```bash
./patch.sh --debug     # 仅签名允许 lldb attach，不装 hook
./patch.sh --monitor   # 前台运行消息监听（Ctrl+C 退出）
```

---

## 风险说明

1. 微信升级后补丁可能失效，脚本内置自动寻址尽力兼容，但无法应对函数实现的根本变化
2. 仅承诺已验证版本（4.1.9 / 4.1.10），其他 build 号尽力支持
3. 仅用于技术研究，请自行承担使用风险

---

## 旧版本（微信 3.7.0）

支持微信 3.7.0 及更早版本，基于 Method Swizzling，支持聊天框内撤回提示 + 自定义前缀。

<img width="301" alt="image" src="https://user-images.githubusercontent.com/18585610/159691061-3f24b69f-a494-4549-a530-7724b1b40060.png">

```bash
# 安装：将 Install.sh 拖到终端执行
# 卸载：将 Uninstall.sh 拖到终端执行
```

[微信 v3.7.0 下载](https://dldir1.qq.com/weixin/mac/WeChatMac.dmg)
