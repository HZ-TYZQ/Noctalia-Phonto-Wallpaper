# 已知问题

审查日期：2026-10-09。以下记录基于审查时的工作区代码（含尚未提交的 v0.3.0 改动），不代表后续修复状态。

初次审查未修改功能代码，以下“问题”和“验证情况”保留当时的记录；当前修复结果见各条“状态”。修复复核包括模拟 Noctalia 接口测试、替身 phonto 的真实进程测试和本机 ffmpeg 提帧测试；尚未进行真实桌面环境中的热插拔和完整交互验证。

2026-10-09 更新：以下 6 项均已修复，见各条“状态”；回归测试用 `tests/run.sh` 运行。

## 1. 启动失败后仍隐藏桌面壁纸

- **严重程度：高**
- **位置：** [phonto_service.luau](../phonto-wallpaper/phonto_service.luau)，`launch`、`confirmRunning`、`coverWithThumbnails`（原隐藏定时器为 `hideHostWallpaperSoon`）。
- **触发条件：** 视频已被删除、解码失败，或 systemd 启动失败等导致 phonto 无法正常显示壁纸。
- **问题：** 启动命令后台执行后，固定等待 0.8 秒就隐藏 Noctalia 壁纸，没有确认 phonto 是否启动成功，也没有故障恢复逻辑，可能导致黑屏。启动命令的输出也被丢弃，难以定位原因。
- **验证情况：** 静态检查及模拟接口确认隐藏壁纸不依赖进程启动结果；未在真实桌面注入启动故障。
- **建议：** 确认进程启动及壁纸就绪后再隐藏原壁纸；启动失败或进程退出时恢复原壁纸，并保留错误信息。
- **状态：** 已修复。启动 0.8 秒后用 pgrep 确认进程仍在运行才隐藏原壁纸，之后每 5 秒检查一次；启动失败或进程退出时恢复原壁纸并发通知，phonto 的输出保存在 `~/.local/state/noctalia/phonto/phonto.log`。回归测试：`tests/service_sim.lua`、`tests/service_shell.lua` 中的 `#1` 检查。
- **复核补充：** 修复了无缩略图缓存时重启仍隐藏原壁纸的遗漏；现在等待启动确认期间始终显示 Noctalia 壁纸，有缓存时使用缩略图，无缓存时保留现有图片。新增回归用例已先复现失败，再验证修复。
- **验证边界：** pgrep 只能确认进程存活，不能确认首帧已显示；仍存活但卡住的渲染进程不在本次检测范围内。日志目录遵循 `XDG_STATE_HOME`，上述路径为默认值。

## 2. 重启后暂停状态与界面不同步

- **严重程度：中**
- **位置：** [phonto_service.luau](../phonto-wallpaper/phonto_service.luau)，`stopInstance`、`reconcile`、`onOutputsChanged`、`onConfigChanged`。
- **触发条件：** 暂停播放后，修改设置，或热插拔显示器使播放进程重启。
- **问题：** `stopInstance` 将内部 `paused` 状态重置为 `false`，新进程恢复播放，但这些调用路径没有重新发布暂停状态，界面可能仍显示“继续”。
- **验证情况：** 模拟接口已复现修改配置和拔除已分配显示器两种情况；共享状态仍为暂停，再发送 `toggle` 会再次进入暂停。
- **建议：** 在重启完成后统一发布实际状态，确保所有触发重启的路径都能同步界面。
- **状态：** 已修复。每次重启（包括只停不启）完成后统一发布状态。回归测试：`tests/service_sim.lua` 中的 `#2` 检查。

## 3. 切换视频期间暂停请求可能丢失

- **严重程度：中**
- **位置：** [phonto_service.luau](../phonto-wallpaper/phonto_service.luau)，`stopInstance`、`setPaused`。
- **触发条件：** 切换视频后，在旧进程停止、新进程尚未启动的时间窗口内发送暂停命令。
- **问题：** 等待停止期间 `instance` 为 `nil`，`setPaused` 直接返回，暂停请求没有保存；新视频启动后继续播放。
- **验证情况：** 模拟异步停止回调，已复现暂停请求被丢弃。
- **建议：** 保存期望的暂停状态，在新进程就绪后应用；明确普通重启和重启期间新收到的暂停请求之间的优先级。
- **状态：** 已修复。普通重启恢复播放；重启期间（旧进程停止中，或新进程尚未通过启动确认）收到的暂停/继续请求会保存下来，在启动确认通过后应用，界面立即显示该请求。回归测试：`tests/service_sim.lua` 中的 `#3` 检查。

## 4. 缩略图缓存名冲突

- **严重程度：中**
- **位置：** [panel.luau](../phonto-wallpaper/panel.luau)，`cachePath`；[phonto_service.luau](../phonto-wallpaper/phonto_service.luau)，`coverWithThumbnails`。
- **触发条件：** 多个视频路径替换非字母数字字符后得到相同字符串，中文文件名尤其容易触发。
- **问题：** 缓存名使用 `path:gsub("[^%w]", "_")`，不同视频可能读写同一张图片，造成缩略图串图或覆盖，也会影响启动时的过渡壁纸。
- **验证情况：** 已确认同一目录下的 `天空.mp4` 和 `大海.mp4` 生成相同缓存名。
- **建议：** 使用完整路径的稳定哈希生成缓存名，并保持面板和服务端算法一致；如需支持原路径视频被替换，再加入缓存失效机制。
- **状态：** 已修复。缓存名改为完整路径的两个 32 位多项式哈希（`thumbName`），面板与服务端共用同一段代码，测试检查两份完全一致。旧命名的缓存文件不再使用，会按新名重新生成。未加入缓存失效机制。回归测试：`tests/service_sim.lua`、`tests/service_shell.lua` 中的 `#4` 检查。

## 5. “所有输出”模式下 IPC 单屏停止无效

- **严重程度：中**
- **位置：** [phonto_service.luau](../phonto-wallpaper/phonto_service.luau)，`clearVideo`；[README.md](../phonto-wallpaper/README.md)，IPC Commands。
- **触发条件：** 使用 `assignments["*"]` 全屏播放时，执行 `clear <connector>`。
- **问题：** 该命令只删除指定显示器的独立配置，没有处理通配配置。后续协调仍保留所有输出的播放，并再次隐藏该屏的原壁纸，与 README 中“停止指定显示器”的描述不符。面板对通配模式下的单屏停止已有禁用限制，但 IPC 没有对应处理或说明。
- **验证情况：** 模拟接口已确认通配配置保留，指定显示器的原壁纸重新被隐藏。
- **建议：** 若支持通配模式下单屏停止，将通配配置转换为其余显示器的独立配置；否则明确拒绝该操作，并在 IPC 文档中说明限制。
- **状态：** 已修复。通配模式下 `clear <connector>` 会把通配配置转换为其余在线显示器的独立配置，README 已说明。回归测试：`tests/service_sim.lua` 中的 `#5` 检查。

## 6. 不足 1 秒的视频无法生成缩略图和静态回退画面

- **严重程度：低**
- **位置：** [panel.luau](../phonto-wallpaper/panel.luau)，`pumpThumbQueue`；[phonto_service.luau](../phonto-wallpaper/phonto_service.luau)，`extractStaticWallpaper`。
- **触发条件：** 视频时长不足 1 秒。
- **问题：** 两处提帧命令都固定使用 `-ss 1`，超出视频时长时无法得到图片，面板保留空白预览，停止播放时也无法生成对应静态画面。
- **验证情况：** 本机用 0.4 秒视频运行当前命令，未生成图片；改取首帧成功。2 秒视频使用当前命令正常。另一次显式指定像素格式的测试中，ffmpeg 返回成功但仍无输出文件，因此不能只依据退出码判断提帧成功。
- **建议：** 在 1 秒位置提帧失败或没有生成有效图片时，回退到首帧，并检查实际输出文件。
- **状态：** 已修复。提帧命令（`frameCommand`，面板与服务端共用）先删除旧文件，1 秒处没有得到非空图片时回退到首帧，并以输出文件非空作为成功条件。回归测试：`tests/service_sim.lua`、`tests/service_shell.lua` 中的 `#6` 检查。

## 已通过的检查

- `bash tests/run.sh`：379 项检查通过，0 失败（异步模拟 155、同步模拟 138、替身 phonto 的真实进程测试 86）。真实进程测试包含 systemd 作用域、信号、启动失败、进程崩溃和 ffmpeg 提帧；本次未运行会在桌面绘制测试图案的 `--phonto` 测试。
- `noctalia plugins lint phonto-wallpaper`：0 errors，0 warnings。
- 所有翻译文件与英文基准的键一致。
- `catalog.toml` 与 `plugin.toml` 的版本号一致，均为 `0.3.0`。
- `git diff --check`：通过。
