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

### 九种标注 + 选择/移动/删除

矩形、椭圆、直线、箭头、画笔、荧光笔、文字、马赛克、序号标记。选择工具可以点选已画的标注拖动位置、Delete 删除、双击文字重新编辑。撤销/重做是快照式的，移动和删除都能回退。

工具栏显示哪些工具、默认颜色和粗细、截完是复制还是落盘，都在 DMS 设置页里配置。

### 快：按下到画面变暗约 82ms

| 阶段 | 耗时 |
|---|---|
| 按下快捷键 → 画面变暗、可以开始拉选区 | **~82ms** |
| → 冻结帧完全解码就位 | ~172ms |

起初是 324ms 才有任何反应，慢得能明显感觉到。拆开逐个处理后压到 82ms，做法见下面的[延迟](#延迟)一节——其中最有效的一条是：遮罩不必等图片解码完，因为冻结帧和此刻的实时桌面本来就是同一幅画面。

### 导出是原分辨率，不是缩放糊图

HiDPI 屏上按物理像素导出：1920×1080@2x 的屏幕上选 500×400 的逻辑区域，出来的是 **1000×800** 的真实像素，文字 1:1 锐利。马赛克也是在源像素上做的，不是把糊图放大。

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

绑到 niri：

```kdl
Mod+Shift+S { spawn "dms" "ipc" "call" "screenshotPlus" "capture"; }
```

### 选区

| 操作 | 效果 |
|---|---|
| 拖动空白处 | 拉出选区 |
| 拖动选区内部（未选工具时） | 整体移动选区 |
| 拖动 8 个圆点 | 调整选区边界 |
| `Enter` / ✓ | 按设置输出（默认复制到剪贴板）并结束 |
| `Ctrl+C` / 复制按钮 | 复制到剪贴板 |
| `Ctrl+S` / 保存按钮 | 保存到文件（通知里带「打开 / 打开目录」） |
| `Esc` / 右键 | 逐层退出：编辑中的文字 → 选中的标注 → 当前工具 → 整个截图 |

### 工具

| 工具 | 键 | 操作 |
|---|---|---|
| 选择 | `S` | 点选标注；拖动移动；`Delete` 删除；双击文字进入编辑 |
| 矩形 / 椭圆 / 直线 / 箭头 / 马赛克 | `R` `E` `L` `A` `M` | 在选区内拖出 |
| 画笔 / 荧光笔 | `P` `H` | 在选区内画 |
| 文字 | `T` | 点一下开始输入；`Enter` 提交，`Shift+Enter` 换行，`Esc` 取消，点别处也提交；支持输入法 |
| 序号 | `N` | 点一下放一个自增编号；删掉中间的会自动重排 |
| 撤销 / 重做 | `Ctrl+Z` / `Ctrl+Shift+Z` | 快照式，移动和删除也能回退 |

工具栏的调色板按钮打开样式面板：8 个预设色 + 自定义（DMS 的取色器），以及 S / M / L / XL 四档粗细。**每个工具记住自己的粗细**——画笔选了 L 不影响文字的字号。

### 设置

DMS 设置 → 插件 → Screenshot+：

- **工具栏**：每个工具一个开关。关掉的不显示，快捷键也失效
- **默认样式**：颜色、粗细档
- **输出**：复制到剪贴板 / 保存到文件 / 保存目录（留空 = 系统图片目录下的 `Screenshots`）/ 完成后通知
- **冻结帧后端**：`cli`（默认）或 `screencopy`（快但要求修复过的 Quickshell，见[坑 1](#1-️-screencopy-后端会崩溃整个桌面quickshell-上游-bug已定位到根因)）

## IPC

```
dms ipc call screenshotPlus capture                  # 唤起 overlay（绑快捷键用这个）
dms ipc call screenshotPlus captureWith <backend>    # 本次用 cli | screencopy，不持久
dms ipc call screenshotPlus setBackend <backend>      # 持久切换后端（等价于设置页）
dms ipc call screenshotPlus cancel                   # 关闭
dms ipc call screenshotPlus finish                   # 按设置输出并结束
dms ipc call screenshotPlus finishWith <intent>      # default | copy | save
dms ipc call screenshotPlus status                   # JSON：选区、工具、颜色、各工具粗细、历史深度、生效的设置、耗时
dms ipc call screenshotPlus select <x> <y> <w> <h>   # 不用鼠标设定选区（全局逻辑坐标）
dms ipc call screenshotPlus setTool <tool>           # 切换工具（禁用的工具返回 BAD_TOOL）
dms ipc call screenshotPlus setColor <#rrggbb>
dms ipc call screenshotPlus testStrokeTool <tool>    # 在选区内放一笔代表性的标注
dms ipc call screenshotPlus testAll                  # 所有启用工具各放一笔，网格排布
dms ipc call screenshotPlus hitTest <x> <y>          # 该点命中的标注 {id, tool} 或 null
dms ipc call screenshotPlus selectStroke <id> | moveSelected <dx> <dy> | deleteSelected
dms ipc call screenshotPlus undo | redo | strokesJson
```

这些让整条链路可以脱离鼠标做回归：

```bash
dms ipc call screenshotPlus capture; sleep 1.5
dms ipc call screenshotPlus select 200 150 1200 800
dms ipc call screenshotPlus testAll
dms ipc call screenshotPlus finishWith save; sleep 2
identify "$(dms ipc call screenshotPlus status | jq -r .lastSaved)"
# 1920x1080@2x 的屏幕上必须是 2400x1600
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
| `ScreenshotPlusDaemon.qml` | 共享状态（选区、strokes + 快照历史、工具/颜色/各工具粗细、选中项）、冻结帧编排、从设置派生的行为、导出后处理（剪贴板 / 落盘 / 通知）、IPC |
| `CaptureOverlay.qml` | 每屏一个全屏 layer-shell 窗口：坐标换算、冻结帧、遮罩、选区与把手、主 MouseArea 按工具类型分派、键盘、导出、取色器的焦点切换 |
| `AnnotationLayer.qml` | 导出子树（帧副本 / 马赛克层 / 已提交笔画 / 正在画的一笔）+ 作为**兄弟节点**的选中框和文字编辑器 |
| `Toolbar.qml` | `DankActionButton` 工具栏 + 颜色/粗细面板；用 `Loader` 挂载，随选区一起销毁 |
| `ScreenshotPlusSettings.qml` | DMS 设置页 |
| `lib/Tools.js` | 工具注册表（唯一真源）：图标、快捷键、交互类型 `drag/path/click/text/select`、S/M/L/XL 粗细表 |
| `lib/Renderer.js` | 在 Canvas 上画每种笔画；序号按创建序临时编号 |
| `lib/Hit.js` | 包围盒、按工具的命中测试、平移（返回新对象，从不改原 stroke） |
| `lib/Config.js` | 设置的默认值，daemon 与设置页共用一份 |

### 数据模型

```js
stroke = { id, tool, color, width, points: [{x, y}, …],   // 全局逻辑坐标；两点类不归一化，消费方 min/max
           text, w, h, lineHeight, font }                   // 仅文字
// width 的语义按工具：线宽 | 字号 | 马赛克块大小 | 序号半径
```

stroke 进入 `strokes` 之后视为不可变；移动、改文字都生成新对象整体替换数组。这样撤销历史只是「数组快照的数组」，共享 stroke 引用，画笔的几千个点不会被复制；QML 也总能看到变化（它检测不到就地修改）。

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

马赛克是同一招的反用：每个马赛克矩形一个 `ShaderEffectSource`，`sourceRect` 对准那块区域，`textureSize` 故意缩到「矩形尺寸 ÷ 块大小」，显示时 `smooth: false` 用最近邻放大——像素化在 GPU 上完成，两种后端通用，导出时随子树一起 grab。选这条路是因为 Canvas 拿不到像素：`drawImage` 不接受 Image item，`ScreencopyView` 又没有 URL 可 `loadImage`。

### 两种 backend

| | 画面变暗 | 冻结帧就绪 | 状态 |
|---|---|---|---|
| `cli`（默认） | ~82ms | ~172ms | 任何 Quickshell 都稳定 |
| `screencopy` | — | **~53ms** | ⚠️ 需要打了 [quickshell#1094](https://github.com/quickshell-mirror/quickshell/issues/1094) 补丁的 Quickshell；原版 ≤ 0.3.1 **会崩掉整个 shell**，见下 |

CLI 路径：`dms screenshot output -o <name> --dir /tmp --json`，落盘再显示。JSON 直接返回 `scale`，不必自己查缩放。screencopy 路径：`ScreencopyView` 直接拿合成器的帧，没有编码、落盘、解码三步，画面一出来就是冻结帧。

默认永远是 `cli`，因为插件无法探测 Quickshell 有没有打补丁。确认自己的 Quickshell 已修复后，`dms ipc call screenshotPlus setBackend screencopy` 持久切换。

---

## 踩过的坑（务必先读）

### 1. ⚠️ screencopy 后端会崩溃整个桌面（Quickshell 上游 bug，已定位到根因）

`ScreencopyView` 能抓到干净的帧（已验证不会套娃），速度也远胜 CLI。但 overlay 隐藏时 Quickshell 会段错误，**整个 DMS 连同 bar 一起挂掉**。四次崩溃栈完全一致，`QS_DISABLE_DMABUF=1`（走 SHM）照崩，所以**与 dmabuf / NVIDIA 无关**。上游 [quickshell#876](https://github.com/quickshell-mirror/quickshell/issues/876)（niri + PanelWindow + ScreencopyView 反复开关）和 [#193](https://github.com/quickshell-mirror/quickshell/issues/193) 是同一个问题，但都没人给出原因；完整的根因分析（core 数据、协议流、源码引用、修法建议）已提交为 [quickshell#1094](https://github.com/quickshell-mirror/quickshell/issues/1094)。

**根因：Quickshell 用 Qt 自己的 `QtWayland::wl_output` 类对同一个显示器又 bind 了一份 `wl_output`，Qt 把这个代理误认成自己的屏幕。** 链条四环，每一环都有实证：

1. **Quickshell 多绑一份 `wl_output`。** `WlrScreencopyContext` 里内嵌的 `OutputTransformQuery : public QtWayland::wl_output`（`wlr_screencopy_p.hpp:48`）在构造时 `init(registry, globalId, 3)` 重新 bind 显示器的 global，只为读一个 `transform` 字段——源码注释自称 "cursed hack"。析构时 `release()`。协议流：
   ```
   bind(46, "wl_output", 4, #21)   ← Qt 启动时绑的
   bind(46, "wl_output", 3, #38)   ← 每次 screencopy 会话 Quickshell 再绑一份
   ```
2. **niri 对每个代理都发 `enter`。** smithay 的 `Output::enter()` 遍历该客户端**所有** `wl_output` 资源逐个 `surface.enter()`（`src/wayland/output/mod.rs:308`）。协议流里同一个 surface 连着收到 `enter(wl_output#21)` 和 `enter(wl_output#38)`。
3. **Qt 的身份校验形同虚设。** `QWaylandScreen::fromWlOutput()` → 生成代码 `wl_output::fromObject()` 只比较监听器地址是否等于 `&m_wl_output_listener`——而 Quickshell 调的正是 Qt 的 `init()`，装的就是这同一个静态监听器，校验必然通过。于是 `static_cast<QWaylandScreen*>(user_data)` 把 `OutputTransformQuery` 对象**减去 16 字节**（`wl_output` 在 `QWaylandScreen` 里的基类偏移，gdb 实测）后当成 `QWaylandScreen` 塞进 `m_screens`。
4. **悬空项永远清不掉。** 会话结束 `release()` 掉的代理不会再收到 `leave`；而 overlay 隐藏时 Qt 真正的屏幕却被 `leave(#21)` 正常移除。core 里崩溃窗口的 `m_screens` 只剩 **一个** 元素 `0x7fb5cdc90110`，与 display 里活着的屏幕 `0x7fb62b875c40` 完全不是一个东西；它指向已 `delete` 的 context 内存（前后 48 字节全零），`oldestEnteredScreen()` 对它调 `->screen()` 时读 `d_ptr` 得 0，SIGSEGV。

为什么裸的最小复现多半不崩、DMS 稳定崩：hide 时 Quickshell 把 QWindow `deleteLater()`，unmap 的 `commit` 又要等事件循环空闲才 flush——两者在同一轮循环里发生，合成器还没看到 unmap，surface 就已经没了，它回的 `leave` 被 `discarded`。**只有当 tick 中途有人 flush 了连接、且 tick 比合成器一个来回更长时才会崩**：threaded 渲染循环下其它窗口一重绘，渲染线程 `eglSwapBuffers` 就把主线程排队的 unmap 一起冲出去了，`leave` 回来排在队列里，下一次 `awake` 先派发它、后执行 DeferredDelete。DMS teardown 时 bar 恰好在重绘。给最小复现加一个持续动画的窗口 + hide 后忙等 30ms，就 3/3 必崩，栈完全一致（见 issue）。

复现于 Quickshell 0.3.1（master 上 `OutputTransformQuery` 未变）+ Qt 6.11.2 + niri 26.04。「对每个 `wl_output` 资源各发一次 `enter`」是协议层的标准行为：smithay 这么做，wlroots 的 `wlr_surface_send_enter()` 也遍历全部资源，还会在客户端新 bind 时对已有 surface 补发——sway/Hyprland 同样会触发，合成器无责。

**修法在 Quickshell 侧**。`QtWayland::wl_output` 是 Qt 的私有生成类，Qt 内部默认「进程里每个这样的实例都是 `QWaylandScreen`」（`fromWlOutput` 的 `static_cast` 就建立在这上面）；Quickshell 拿它派生了一个不是屏幕的东西，打破了这条约定。修法是保留那份额外 bind，但**用自己的 `wl_output_listener`** 手动 `wl_registry_bind` + `wl_output_add_listener`——`fromWlOutput` 认不出它就会直接忽略。

走过一条弯路值得记下：直觉上更干净的做法是根本不额外 bind，直接读 `QWaylandScreen::mTransform`（它是 protected，`setScreen()` 已经用 reflector 读同一段里的 `m_outputId`）。**这不行**——Qt 在 `updateOutputProperties()` 里用完就把它重置成 -1，而 `QScreen::orientation()` 又明确忽略四种 flipped 变换。实测这样改出来的版本在 `transform 90` 的屏幕上抓到的是没旋转的横图。私有 listener 的版本在本机 v0.3.1 和 master 上都验证过：确定性复现 3/3 跑满，正常与旋转 90° 的抓帧都和 `dms screenshot` 一致。

Qt 侧把 `static_cast` 换成 `dynamic_cast` 也能免疫，但那是加固不是根治。插件侧没有可靠的规避手段（悬空项在 `enter` 时就已经种下）。

补丁在 [pcmid/quickshell 的 `screencopy-private-output-listener` 分支](https://github.com/pcmid/quickshell/tree/screencopy-private-output-listener)，已提交上游。打上补丁（Arch 可用官方 PKGBUILD 加 `prepare()` 自行打包）后 `setBackend screencopy` 即可；没打补丁就别开，会崩 shell。

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

### 9. 子组件属性名不能和外层 id 同名

`Toolbar { win: win }`——右边的 `win` 会先解析成 Toolbar **自己**的 `win` 属性，得到 null（工具栏跑到了屏幕左上角）。直接声明在父组件里时有时能侥幸解析到 id，放进 `Loader` / `Repeater` 的 Component 里就必然自引用。给传递用的属性起一个不会与任何 id 重名的名字（这里用 `overlay`）。

### 10. `id: layer` 会被 `Item.layer` 遮住

每个 `Item` 都有 `layer` 分组属性（`layer.enabled` 那个）。给根元素起 `id: layer` 之后，在 Repeater delegate 里写 `layer.frameItem`，解析到的是 delegate 自己的 `Item.layer`，值是 undefined——马赛克的 `sourceItem` 因此为 null，没有任何报错。同理避开 `parent`、`children`、`anchors`、`data` 这类名字。

---

## 待办

resize 已画的标注（现在只能移动）→ 多屏（跨屏选区、多个 Exclusive 键盘层的冲突）→ 高斯模糊（需要 shader，Canvas 做不了）。

画笔实时预览用的是全屏尺寸的 Canvas，4K 下拖动时若掉帧，把活动层缩到笔画的 bounding box。
