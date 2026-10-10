# QQ Plugin Manager（巨魔注入版插件管理器）

一个**零依赖**的 dylib 插件：注入 QQ 后，屏幕右下角出现一个可拖动的「管」悬浮球，点击即可打开**插件管理**页面，列出 QQ 进程内所有已安装 / 已加载的 dylib 插件，并查看详情与禁用引导。

## 它能做什么



| 功能   | 说明                                                                       |
| ---- | ------------------------------------------------------------------------ |
| 插件列表 | 扫描 `QQ.app/` 根目录 + `Frameworks/` 下所有 `.dylib`，即 "已安装" 全集                 |
| 加载状态 | 通过 `_dyld_image_count()` 枚举比对，区分 **● 已加载** / **○ 未加载**                   |
| 插件详情 | 文件名、安装名（LC\_ID\_DYLIB）、版本、架构（arm64/arm64e/fat）、绝对路径、依赖链（LC\_LOAD\_DYLIB） |
| 分类展示 | QQ.app 根目录（注入插件）与 Frameworks 目录分区显示；本工具自身标蓝                              |
| 禁用引导 | 明确说明哪些插件可禁用、如何用注入器移除，并一键复制插件名                                            |

能直接看到：`120hz箱子(1).dylib`、`FakeTools(2) (1).dylib`、`QQBaby1.1.5(2) (1).dylib`、`q_theme.dylib`、`libsubstrate.dylib`，以及 Frameworks 下**未被主程序加载**的 `NTQQ_AntiRecall.dylib`（会显示为 "未加载"，即装了但没生效）。

## 为什么没有运行时 "开关"

你的 5 个插件都是**静态注入**（主程序 Mach-O 写死 `LC_LOAD_DYLIB`），dyld 在 QQ 启动时已加载并执行了它们的 hook：



* 运行时没有 unhook API，无法安全卸载已 hook 的 dylib；

* 直接改名 / 删除 `QQ.app` 内的 dylib 会让下次启动 dyld 报 `Library not loaded`，**QQ 直接起不来**。

所以正确做法是用注入器（TrollFools 类）在**重新注入时移除**对应插件。本工具负责 "看见一切 + 告诉你怎么办"。

> 提示：如果你只是想 "看到有哪些插件"，巨魔注入器（TrollFools）本身的 App 管理界面就能列出每个 App 的已注入插件并可移除；本工具的价值在于
>
> **在 QQ 运行中随时查看**
>
> ，含未加载项与二进制详情。

## 编译（两种方式）

### 方式 A：GitHub Actions（推荐，无需 Mac）



1. 把本目录（`PluginManager/` 内的全部文件，含 `.github/workflows/build.yml`）上传到任意 GitHub 仓库；

2. 仓库 Actions 页面手动运行 **Build PluginManager**（或 push 自动触发）；

3. 完成后下载 artifact：取其中的 `PluginManager.dylib`（在 `.theos/obj/debug/arm64e/` 下）或 `*.deb` 解包。

### 方式 B：macOS + theos



```
git clone --recursive https://github.com/theos/theos.git \$THEOS

export THEOS=/path/to/theos

make clean

make package

\# 产物：.theos/obj/debug/arm64e/PluginManager.dylib 与 packages/\*.deb
```

> 若你设备不是 arm64e（A12 之前），把 
>
> `Makefile`
>
>  里的 
>
> `ARCHS`
>
>  改为 
>
> `arm64`
>
>  重新编译。

## 注入与使用



1. 用你现有的巨魔注入器把 `PluginManager.dylib` 静态注入 QQ（与其它插件同级放入 `QQ.app`，会自动写入 LC\_LOAD\_DYLIB）；**无需 libsubstrate**；

2. 重启 QQ，屏幕右下角出现半透明「管」悬浮球（可拖动）；

3. 点击悬浮球 → 插件管理列表 → 点任意行看详情 / 禁用引导。

## 工程结构



```
PluginManager/

├── PluginManager.mm            # 全部源码（Mach-O 解析 + 悬浮球 + 列表/详情 UI）

├── Makefile                    # theos 构建配置（ARCHS=arm64e, iOS 14.0+）

├── control                     # deb 包元数据

├── PluginManager.plist         # substrate/ellekit 动态注入时的过滤器（静态注入可忽略）

├── README.md

└── .github/workflows/build.yml # GitHub Actions 自动编译
```

## 实现要点（源码可查）



* **无 hook**：入口是自建悬浮球 + `dispatch_after` 主线程挂载，不碰 QQ 任何方法 → 版本兼容性最好，注入即生效；

* **Mach-O 解析**：支持 thin 64 与 fat（正确处理 fat 大端字节序），读取 LC\_ID\_DYLIB / LC\_LOAD\_DYLIB / CPU 架构；

* **加载判定**：dyld 镜像路径比对 + 文件名兜底（兼容 `/var` 与 `/private/var` 差异）。