# Screenshot+

DankMaterialShell 插件：**选区的同时就能标注**。

niri 和 DMS 自带的截图都是两段式——先选区截图落盘，再打开另一个编辑器（satty/swappy，或 quickCapture 的 modal）。中间断了一次，手要重新找位置。Screenshot+ 把两步合成一步。

## 特点

### 就地编辑，没有第二个窗口

拉出选区，工具栏立刻出现在选区边上，直接开画。不落盘、不切窗口、不等编辑器启动——从按下快捷键到画完第一个框，全程在同一个界面里。

### 拖得动，而且整套跟着走

选区拉出来之后不是定死的：

- 按住选区内部可以整体挪位置，8 个圆点可以改边界
- **工具栏全程贴着选区跟随**，贴近屏幕下沿时自动翻到上方
- **已经画过的标注锚在画面上，不跟着选区跑**——移动选区去框别的地方，先前画的框留在它标的那个位置上

这不是靠事件同步实现的。选区框、工具栏、标注层活在同一个 QML 场景里，工具栏的位置就是绑定到选区矩形的一条表达式，所以它们天然一起动，这部分没有一行同步代码。

### 快：按下到画面变暗约 82ms

| 阶段 | 耗时 |
|---|---|
| 按下快捷键 → 画面变暗、可以开始拉选区 | **~82ms** |
| → 冻结帧完全解码就位 | ~172ms |

起初是 324ms 才有任何反应，慢得能明显感觉到。拆开逐个处理后压到 82ms，做法见下面的[延迟](#延迟)一节——其中最有效的一条是：遮罩不必等图片解码完，因为冻结帧和此刻的实时桌面本来就是同一幅画面。

### 导出是原分辨率，不是缩放糊图

HiDPI 屏上按物理像素导出：1920×1080@2x 的屏幕上选 500×400 的逻辑区域，出来的是 **1000×800** 的真实像素，文字 1:1 锐利。

**当前状态：验证原型**。交互和导出链路已跑通，工具只有矩形框和画笔。

---

## 安装

需要 DankMaterialShell >= 1.6.0。

```bash
git clone https://github.com/pcmid/dms-screenshot-plus.git \
    ~/.config/DankMaterialShell/plugins/screenshotPlus

dms ipc call plugin-scan scan
dms ipc call plugins enable screenshotPlus
```

插件目录名可以随意，DMS 认的是 `plugin.json` 里的 `id`（`screenshotPlus`）。

### 想改代码

克隆到别处再软链进去，这样改完不用来回拷：

```bash
git clone https://github.com/pcmid/dms-screenshot-plus.git
ln -s "$PWD/dms-screenshot-plus" ~/.config/DankMaterialShell/plugins/screenshotPlus

dms ipc call plugin-scan scan
dms ipc call plugins enable screenshotPlus
```

改完 QML 后用 `systemctl --user reload dms` 生效——**不是** `dms ipc call plugins reload`，原因见[坑 2](#2-改了-qml-却没生效--必须-shell-级-reload)。

## 使用

```bash
dms ipc call screenshotPlus capture
```

| 操作 | 效果 |
|---|---|
| 拖动空白处 | 拉出选区 |
| 拖动选区内部 | 整体移动选区 |
| 拖动 8 个圆点 | 调整选区边界 |
| 工具栏 ▭ / ✎ 或 `R` / `P` | 切换矩形框 / 画笔（选中后在选区内拖动即作画） |
| `Ctrl+Z` / `Ctrl+Shift+Z` | 撤销 / 重做 |
| `Enter` 或 `Ctrl+C` 或 ✓ | 复制到剪贴板并发通知 |
| `Esc` / 右键 | 先退出当前工具，再按则取消整个截图 |

绑到 niri：

```kdl
Mod+Shift+S { spawn "dms" "ipc" "call" "screenshotPlus" "capture"; }
```

## IPC

```
dms ipc call screenshotPlus capture                  # 唤起 overlay（绑快捷键用这个）
dms ipc call screenshotPlus captureWith <backend>    # 指定 cli | screencopy
dms ipc call screenshotPlus cancel                   # 关闭
dms ipc call screenshotPlus status                   # JSON 状态 + 耗时
dms ipc call screenshotPlus select <x> <y> <w> <h>   # 不用鼠标设定选区（全局逻辑坐标）
dms ipc call screenshotPlus finish                   # 导出并复制
dms ipc call screenshotPlus testStroke               # 自测：在选区内画一框一线
```

`select` / `finish` / `testStroke` 让整条导出链路可以脱离鼠标做自动化验证：

```bash
dms ipc call screenshotPlus capture; sleep 1.5
dms ipc call screenshotPlus select 400 300 500 400
dms ipc call screenshotPlus testStroke
dms ipc call screenshotPlus finish; sleep 2
wl-paste --type image/png > /tmp/t.png && identify /tmp/t.png
# 1920x1080@2x 的屏幕上，500x400 的逻辑选区必须导出成 1000x800 物理像素
```

`status` 里的 `grabMs` / `readyMs` 是内建的耗时埋点，改动后可直接回归性能。

---

## 延迟

324ms 压到 82ms 的过程（下面的耗时都实测自一块 3840×2160 的屏，绝对值随分辨率变，但三段开销的构成是一样的）。原来的开销是三段，逐个处理：

| 来源 | 处理 |
|---|---|
| `dms ipc call screenshot begin` 子进程（8ms，且串在抓帧前面） | 删掉，QML 里直接设 `PopoutManager.screenshotActive`。 |
| 抓帧 156ms（命令行单跑只要 71ms） | **先发抓帧命令，再映射 overlay**。`dms screenshot` 由同一个进程服务，先映射会让新 layer 的首帧和抓帧抢资源，延迟翻倍。 |
| 4.8MB / 3840×2160 PNG 同步解码约 170ms | 改 `asynchronous: true` 移出渲染线程；并且**遮罩不再等解码**。 |

最后一条是收益最大的，也是最反直觉的一条：

> 遮罩只需要等抓帧命令**返回**（此时它已不可能污染冻结帧），不需要等图片解码完成。而冻结帧的内容和此刻的实时桌面本来就是同一幅画面——所以在解码完成前直接把遮罩压在真实桌面上，等解码好了再无缝换成冻结帧，用户看不出任何切换。

overlay 也因此改成**立刻映射**：抓帧还在飞的时候窗口就已经在了，且全透明（没有遮罩、没有选框，不会被拍进去），指针立即可用。代价是 `finish()` 可能在解码完成前到达，所以它会把导出请求排队，交给 `noteFrameReady()` 执行——否则会存下一张透明图。

---

## 结构

| 文件 | 职责 |
|---|---|
| `ScreenshotPlusDaemon.qml` | IPC、冻结帧编排、共享状态（选区 / 标注栈）、导出后处理 |
| `CaptureOverlay.qml` | `Variants{Quickshell.screens}` → 每屏一个全屏 layer-shell 窗口；遮罩、选区、工具栏、标注、导出 |
| `lib/Renderer.js` | `drawStroke()`——屏上和导出共用同一份，所见即所得 |

### 坐标系

三套，混淆了就会出各种诡异偏移。下表以一块 1920×1080 逻辑分辨率、缩放 2x 的屏幕为例：

| 空间 | 举例 | 用途 |
|---|---|---|
| 全局逻辑 | 该屏在布局中是 (0,0,1920,1080) | **选区和 stroke 的存储格式** |
| 屏幕本地逻辑 | overlay 里的 x/y | = 全局 − 该屏原点 |
| 源图物理像素 | 3840×2160 | 冻结帧的真实尺寸；导出时 × scale |

规则：状态一律存全局逻辑坐标，只在两处转换——overlay 显示时减屏幕原点，导出时乘 scale。因此**标注锚在画面上，不跟着选区跑**：移动选区，画过的框留在原地。

### 导出

`exportRoot` 这棵子树**就是**导出的图：一份自己的冻结帧副本，加上标注，裁剪到选区。对它 `grabToImage()` 拿到的正好是要的结果——不需要裁剪运算。选区的边框/圆点/工具栏是它的**兄弟节点**而非子节点，所以永远不会被拍进去。

帧副本用 `ShaderEffectSource` 复用底下那个 item 已经持有的纹理（screencopy 模式复用 `ScreencopyView`，CLI 模式复用 `Image`），不做第二次捕获、不做第二次 PNG 解码。`textureSize` 钉在源像素上，保证 grab 采样到全分辨率而不是屏幕上的显示尺寸。

### 两种 backend

| | 延迟 | 状态 |
|---|---|---|
| `cli`（默认） | ~82ms | 稳定 |
| `screencopy` | 近乎 0 | ⚠️ **会崩掉整个 shell，见下** |

CLI 路径：`dms screenshot output -o <name> --dir /tmp --json`，落盘再显示。JSON 直接返回 `scale`，不必自己查缩放。

---

## 踩过的坑（务必先读）

### 1. ⚠️ screencopy 后端会崩溃整个桌面

`ScreencopyView` 能抓到干净的帧（已验证不会套娃），速度也远胜 CLI。但 overlay unmap 时释放捕获用的 dmabuf 会让 Quickshell 直接段错误，**整个 DMS 连同 bar 一起挂掉**：

```
#1 QPlatformScreen::screen()
#2 QWaylandWindow::calculateScreenFromSurfaceEvents()
#10 wl_display_dispatch_queue_pending
```

崩溃日志的最后两行正是 `Destroyed WlDmaBuffer(size=3840x2160)` 和 `Destroying GBM device`。复现环境是 NVIDIA + `nvidia-drm`，dmabuf 路径一向脆弱；其它驱动上未验证过，可能不受影响。

所以默认 `cli`。要试就 `captureWith screencopy`，并且知道可能得重启 shell。真要修，方向是**分两阶段拆除**：先把 `captureSource` 置 null，等几帧确认 dmabuf 已释放，再让窗口 unmap——不要让两件事发生在同一帧。

### 2. 改了 QML 却没生效 → 必须 shell 级 reload

`dms ipc call plugins reload <id>` 只对插件的**主组件**做缓存破除（PluginService 给 URL 加 `?t=`）。像 `CaptureOverlay.qml` 这种被相对路径 import 的文件会一直命中 QML 引擎的组件缓存，改了也不会生效——而且没有任何报错，你会看到旧代码的行为，以为是自己逻辑写错了。

```bash
systemctl --user reload dms     # 发 SIGUSR1，整个 shell 重载，这个才有效
```

### 3. IPC 函数少给一个参数会被直接拒绝

Quickshell 不支持可选参数。声明成 `capture(backend: string)` 之后，`dms ipc call screenshotPlus capture` 会因为「参数不足」被拒绝，**函数体一行都不执行**。如果调用时把 stdout 丢进了 `/dev/null`，看到的现象就是「什么都没发生」，非常难查。

所以无参形式必须是独立函数（`capture` / `captureWith`）。调试 IPC 时永远别吞 stdout。

### 4. 插件的 `console.log()` 不进 journald

DMS 把自己的 Logger 单例路由到 journald（那些 `INFO qml: [Name:line]`），插件里的裸 `console.log` 不在其中，**QML 运行时异常也不在**。所以一个抛异常的函数看起来就像"没被调用"。

可用的调试手段：把值塞进 `status` 的 JSON 返回（本插件的 `error` / `grabMs` / `readyMs` 就是这么来的），或者更暴力——把值编码进输出文件名。

### 5. 不要用 Canvas 做图片导出

本插件改用 `grabToImage` 之后就没这个问题了，但如果你想走 Canvas，会连撞两个静默失败：

- `ctx.drawImage(someImageItem, ...)` 什么都不画，哪怕 `status === Image.Ready`、`sourceSize` 正确。必须 `loadImage(url)` 注册到**那个 canvas 自己**的缓存再按 URL 画。
- 9 参数的 `drawImage`（源矩形裁剪）同样静默失败。要裁剪就 `translate` 整张图，靠 canvas 边界裁。

两个都不报错，只是给你一张透明图。

### 6. 导出分辨率的 dpr 换算

`grabToImage` 的 `targetSize` 是**逻辑单位**，Qt 会再乘窗口的 devicePixelRatio。要拿到 N 物理像素得传 `N / dpr`，否则 2x 屏上导出的图正好大一倍。（`Canvas.save()` 反过来，写的是物理像素缓冲。）

`outScale` 和 `dpr` 在分数缩放下并不相等——前者用 `CompositorService.getScreenScale()`，后者是整数 buffer scale——两个都得算进去。

### 7. 离屏 item 用 `opacity: 0`，不要 `visible: false`

`visible: false` 的东西不渲染，grab/save 出来是空的。

### 8. niri 的窗口几何拿不到全局坐标

`niri msg -j windows` 的 `tile_pos_in_workspace_view` 实测恒为 `null`，所以「自动吸附到窗口边界」这类功能做不了，只能走 `dms screenshot window`。

---

## 待办

核心六件套补齐（椭圆 / 箭头 / 文字 / 马赛克）→ 颜色与线宽选择器 → dankbar widget + 设置页 → 多屏（跨屏选区、多个 Exclusive 键盘层的冲突）。

画笔当前用全屏尺寸的 Canvas 做实时预览，4K 下拖动时可能掉帧；若确实卡，把活动层缩到笔画的 bounding box。
