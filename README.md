# DeskBoard

常驻 macOS 桌面的工作台小组件：透明背景，固定在屏幕右下角，层级位于桌面图标之上、普通窗口之下。

| 总任务清单 | 每日任务清单 | 今日计时 |
|---|---|---|
| 长期任务，添加 / 勾选 / 删除 / 双击编辑，永久保存 | 每天纽约时间 08:00（自动处理夏令时）清空 | 从 00:00:00 正计时，开始 / 暂停 / 重置；与每日清单一样在纽约时间 08:00 清零 |

## 构建与安装

需要 macOS 12+ 和 Xcode Command Line Tools（`xcode-select --install`）。

```bash
./build.sh
```

脚本会编译 `DeskBoard.app`，安装到 `~/Applications` 并启动。

## 使用

应用没有 Dock 图标，通过菜单栏的 ☑︎ 图标控制：

- **固定在桌面**：选择它出现在哪个桌面（Space），默认桌面 1
- **置于所有窗口之上**：浮在其他窗口上方，或者回到桌面层
- **缩放**：60% – 100%
- **卡片底色**：透明 / 淡 / 深
- **开机自动启动**：写入 `~/Library/LaunchAgents/local.deskboard.plist`
- **打开数据文件夹**：数据保存在 `~/Library/Application Support/DeskBoard/data.json`

快捷键：空格键开始 / 暂停计时；编辑任务时 Enter 保存、Esc 取消。

## 文件

- `main.swift`：原生外壳，包括透明窗口、桌面固定、菜单栏、数据读写和提示音
- `index.html`：界面与逻辑；单独用浏览器打开也能用（这时数据存在 localStorage）
- `Info.plist`、`build.sh`：打包脚本

> 「固定在桌面」用到了 macOS 的私有 CGS 接口，系统大版本更新后可能失效。失效时，窗口会出现在启动时所在的桌面。
