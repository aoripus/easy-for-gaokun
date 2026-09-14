# 开机画面（Plymouth）实现方案调研报告

**目标设备**：HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / DT `gaokun3`）
**系统**：Ubuntu 26.04 LTS，内核 `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4-dev`（r4dev2 条目）
**调研日期**：2026-09-15
**方法**：平板只读 SSH 取证 + 上游源码（`gitlab.freedesktop.org/plymouth/plymouth`，`main` 分支）逐行核对。
**标注约定**：【已核实】= 有命令输出或源码行号直接支撑；【推测】= 由证据推断，需实机验证。

> 全部取证命令都只读，未修改平板任何文件，未执行任何 git 命令。

---

## 结论速览（先看这个）

| # | 问题 | 结论 |
|:-:|------|------|
| 1 | 版本与插件 | plymouth **24.004.60**，`script.so` **已随包安装**；默认主题 = `bgrt`（`two-step` 模块） |
| 2 | 内核日志怎么进 plymouth | ★ **`script` 插件自带 console viewer**，由 plymouthd 读 `/dev/kmsg` → 经 `on_boot_output` 回调喂进去。**但脚本语言拿不到它**，需要改 C 才能控制位置/行数 |
| 3 | script 可用对象 | `Image` / `Sprite` / `Window` / `Math` / `Plymouth`；**无 Text 对象**（用 `Image.Text`），**无 console viewer API** |
| 4 | 屏幕方向 | ★ plymouth 用 **DRM 渲染器**（fb0 被显式忽略），**`fbcon=rotate` 对它完全无效** ⇒ LOGO 会侧躺 90°。面板不暴露 DRM `panel orientation`，所以必须在**主题里自己旋转** |
| 5 | cmdline 最小改动 | **必须加 `splash`**（不加 plymouthd 根本不起动）；`quiet` **不必加**，加了会看不到日志 |
| 6 | 失败回退 | 四级回退链，**最终一定落到 `text` 主题，不会黑屏**。实测方法见 §6.3 |

**交付物**：`theme/gaokun3-splash.plymouth` + `theme/gaokun3-splash.script` + `theme/logo.png`（+`logo.svg`/`make-logo.ps1`）
+ `theme/viewport-patch-spec.md`（三行视口的 C 改动规格）。

---

## 问题 1 — plymouth 版本、插件、主题、默认主题

### 1.1 命令与原始输出

```
$ dpkg -l | grep -i plymouth
ii  libplymouth5:arm64     24.004.60+git20250831.4a3c171d-0ubuntu8  arm64  ...
ii  plymouth               24.004.60+git20250831.4a3c171d-0ubuntu8  arm64  boot animation, logger and I/O multiplexer
ii  plymouth-label         24.004.60+git20250831.4a3c171d-0ubuntu8  arm64  ... label control
ii  plymouth-theme-spinner 24.004.60+git20250831.4a3c171d-0ubuntu8  arm64  ... spinner theme
```
```
$ ls -la /usr/lib/aarch64-linux-gnu/plymouth/
-rw-r--r-- details.so        (68344)
drwxr-xr-x renderers
-rw-r--r-- label-pango.so    (68328)
-rw-r--r-- script.so         (134496)      <=== 关键
-rw-r--r-- text.so           (68472)
-rw-r--r-- tribar.so         (68464)
-rw-r--r-- two-step.so       (69224)

$ ls /usr/lib/aarch64-linux-gnu/plymouth/renderers/
drm.so  frame-buffer.so
```
```
$ ls /usr/share/plymouth/themes/
bgrt  default.plymouth -> /etc/alternatives/default.plymouth  details  spinner  text  tribar
$ readlink -f /etc/alternatives/default.plymouth
/usr/share/plymouth/themes/bgrt/bgrt.plymouth
$ cat /etc/plymouth/plymouthd.conf
# Administrator customizations go in this file
#[Daemon]
$ cat /usr/share/plymouth/plymouthd.defaults
[Daemon]
ShowDelay=0
DeviceTimeout=8
UseSimpledrm=1
```
```
$ dpkg -l plymouth-themes
un  plymouth-themes  <无>  <无>  (无描述)          # 已卸载/从未安装
$ plymouth-set-default-theme
bash: plymouth-set-default-theme: 未找到命令        # 该命令属于 plymouth-themes 包
```

### 1.2 结论【已核实】

* **版本**：`24.004.60+git20250831.4a3c171d-0ubuntu8`（很新，含上游新架构：`src/daemon/plymouthd-*.c` 模块化拆分、
  console viewer、`panel orientation` 支持）。
* **可用 splash 插件**：`details` / `label-pango` / **`script`** / `text` / `tribar` / `two-step`。
  **没有** `console-viewer.so`（上游有 `src/plugins/splash/console-viewer/`，但 Ubuntu 未打包）。
* **渲染器**：`drm.so` 与 `frame-buffer.so`，两者都在 initramfs 里也有。
* **已安装主题**：`bgrt`（默认，走 `two-step`）、`details`、`spinner`、`text`、`tribar`。
* **当前默认主题 = `bgrt`**（ACPI BGRT 背景图 + spinner）。`/etc/plymouth/plymouthd.conf` 只有注释、无 `Theme=`，
  所以走 `default.plymouth` 符号链接。
* `plymouth-set-default-theme` **不存在**（属于未安装的 `plymouth-themes`）⇒ 安装脚本
  **不能依赖它**，必须直接写 `/etc/plymouth/plymouthd.conf` 的 `Theme=` 或替换 alternative。

### 1.3 ★ 附带发现：initramfs 里**没有** `script.so`【已核实】

```
$ lsinitramfs /boot/initrd.img-$(uname -r) | grep plymouth
etc/plymouth/plymouthd.conf
scripts/init-bottom/plymouth
scripts/init-premount/plymouth
scripts/panic/plymouth
usr/bin/plymouth
usr/lib/aarch64-linux-gnu/plymouth/details.so
usr/lib/aarch64-linux-gnu/plymouth/label-pango.so
usr/lib/aarch64-linux-gnu/plymouth/renderers/drm.so
usr/lib/aarch64-linux-gnu/plymouth/renderers/frame-buffer.so
usr/lib/aarch64-linux-gnu/plymouth/two-step.so        <=== 只有当前主题的模块
usr/sbin/plymouthd
usr/share/plymouth/themes/bgrt/bgrt.plymouth
usr/share/plymouth/themes/default.plymouth
usr/share/plymouth/themes/details/details.plymouth
usr/share/plymouth/themes/spinner/  (animation-000x.png ...)
```

原因在 `/usr/share/initramfs-tools/hooks/plymouth` 里【已核实】：它**只把当前默认主题的 `ModuleName` 对应的
`.so` 和该主题目录拷进 initramfs**（`MODULE="${PLUGIN_PATH}/$(sed -n 's/^ModuleName=\(.*\)/\1/p' ${THEMES}/${currtheme}/${currtheme}.plymouth).so"`），
再加 `details.so label-pango.so` 兜底。

**影响与对策**：换主题后**必须重新生成 initramfs**（`update-initramfs -u -k <ver>`），
否则 initramfs 阶段会缺 `script.so`，plymouthd 会回退到 `details`/`text`（见 §6），看起来"主题没生效"。

---

## 问题 2 — ★ 内核/启动日志到底走哪条通路进 plymouth

### 2.1 决定性发现：`script` 插件**自带 console viewer**【已核实】

在平板二进制上直接取证：

```
$ nm -D --undefined-only /usr/lib/aarch64-linux-gnu/plymouth/script.so | grep -i console
                 U ply_console_viewer_clear_line
                 U ply_console_viewer_convert_boot_buffer
                 U ply_console_viewer_draw_area
                 U ply_console_viewer_free
                 U ply_console_viewer_hide
                 U ply_console_viewer_new
                 U ply_console_viewer_preferred
                 U ply_console_viewer_print
                 U ply_console_viewer_set_text_color
                 U ply_console_viewer_show
                 U ply_console_viewer_write

$ nm -D --defined-only /usr/lib/aarch64-linux-gnu/libply-splash-graphics.so.5 | grep -i console
000000000000b000 T ply_console_viewer_new
000000000000ab68 T ply_console_viewer_preferred
... （11 个全部导出）

$ strings -a /usr/lib/aarch64-linux-gnu/plymouth/script.so | grep -i -E 'ConsoleLog|Monospace'
MonospaceFont
monospace 10
ConsoleLogTextColor
ConsoleLogBackgroundColor
plymouth.prefer-fbcon
Using console viewer instead of kernel framebuffer console
```

⇒ **Ubuntu 26.04 的 `script.so` 完整编译进了 console viewer 支持**，且它读 4 个配置键。

### 2.2 完整数据通路（源码行号）

上游 `main` 分支：

1. **plymouthd 读 `/dev/kmsg`**
   - `strings /usr/sbin/plymouthd` 含：`ply_kmsg_reader_start` / `ply_kmsg_reader_new` /
     `ply_kmsg_reader_watch_for_messages` / `%-75.75s: Creating new kmsg reader`。
   - 实现：`src/libply-splash-core/ply-kmsg-reader.c`。
   - 打开条件由 `ply_show_new_kernel_messages()` 控制；`quiet`/`loglevel` 决定 `/dev/kmsg` 里有多少内容。

2. **daemon 把日志喂给插件**（`src/libply-splash-core/ply-boot-splash.c:625-626`）
   ```c
   if (splash->plugin_interface->on_boot_output != NULL)
           splash->plugin_interface->on_boot_output (splash->plugin, output, size);
   ```
   另外 `ply_boot_splash_show()` 会把**已累积的 boot buffer** 一起交给插件
   （`ply-boot-splash.c:550` 附近，`splash->boot_buffer`）。

3. **`script` 插件把它塞进 console viewer**（`src/plugins/splash/script/plugin.c`）
   ```c
   /* add_display(), 行 555-563 */
   if (ply_console_viewer_preferred ()) {
           script_display->console_viewer = ply_console_viewer_new (
                   script_display->pixel_display, data->monospace_font);
           ply_console_viewer_set_text_color (...);
           if (data->boot_buffer)
                   ply_console_viewer_convert_boot_buffer (...);
   } else {
           script_display->console_viewer = NULL;
   }
   ```
   ```c
   /* on_boot_output(), 行 723-748 */
   static void
   on_boot_output (ply_boot_splash_plugin_t *plugin,
                   const char               *output,
                   size_t                    size)
   {
           if (!ply_console_viewer_preferred ())
                   return;
           ...
           if (display->console_viewer != NULL)
                   ply_console_viewer_write (display->console_viewer, output, size);
   }
   ```
   接口结构体（行 750-779）里 **`.on_boot_output = on_boot_output`** 已接好。

4. **console viewer 自己维护"只显示最新 N 行"**（`src/libply-splash-graphics/ply-console-viewer.c`）
   - 构造：行 96、标签数 = 行 119-124
     ```c
     console_viewer->line_max_chars = ply_pixel_display_get_width (display)
                                      / console_viewer->font_width - 1;
     line_count = ply_pixel_display_get_height (display) / console_viewer->font_height;
     ```
   - 写入：`ply_console_viewer_write()` 行 366-371 → `ply_terminal_emulator_parse_lines()`
   - **滚动**：`update_console_messages()` 行 168-253，行 185-194 取出最后 `visible_line_count` 行：
     ```c
     message_number = ply_terminal_emulator_get_line_count (...);
     if (message_number < visible_line_count) message_number = 0;
     else message_number = number_of_messages - visible_line_count;
     ```
     ⇒ **"新行从下往上顶、旧行滚出"这个行为已经原生具备**。
   - **定位**：`ply_console_viewer_show()` 行 255-282，行 274-276
     ```c
     ply_label_show (console_message_label, console_viewer->display,
                     console_viewer->font_width / 2,
                     console_viewer->font_height * label_index);
     ```
     ⇒ **硬编码左上角**，且行数由屏幕高度决定（1600×2560 + Ubuntu Mono 11 ≈ 105 行）。
   - 绘制：`ply_console_viewer_draw_area()` 行 284-314。

5. **开关**：`ply_console_viewer_preferred()`（行 60-93）
   ```c
   if (ply_kernel_command_line_has_argument ("plymouth.prefer-fbcon")) -> 不用 viewer
   label = ply_label_new (); ply_label_set_text (label, " ");
   if (ply_label_get_width (label) <= 1 || ply_label_get_height (label) <= 1) -> 不用 viewer
   else -> "Using console viewer instead of kernel framebuffer console"
   ```
   ⇒ **默认启用**（除非显式加 `plymouth.prefer-fbcon`，或字体渲染坏了）。

### 2.3 ★ 直接回答"自定义 script 主题能不能拿到内核消息"

**不能通过脚本语言拿到。但脚本主题的屏幕上确实会显示内核消息——由插件内部的 console viewer 完成。**

* 脚本语言**没有** `SetBootOutputFunction`、没有 `Plymouth.SetMessageFunction` 取内核消息这回事：
  `Plymouth.SetMessageFunction` 是 `Plymouth.SetDisplayMessageFunction` 的**别名**
  （`src/plugins/splash/script/script-lib-plymouth.script` 第 2 行），只收
  `plymouth display-message --text=...` 或 `plymouth message` 送来的字符串，**不是内核日志**。
* 脚本能拿到的全部 Plymouth 回调（`script-lib-plymouth.c` 注册，共 18 个）：
  `SetRefreshFunction` / `SetRefreshRate` / `SetBootProgressFunction` / `SetRootMountedFunction` /
  `SetKeyboardInputFunction` / `SetUpdateStatusFunction` / `SetDisplayNormalFunction` /
  `SetDisplayPasswordFunction` / `SetDisplayQuestionFunction` / `SetDisplayPromptFunction` /
  `SetDisplayHotplugFunction` / `SetValidateInputFunction` / `SetDisplayMessageFunction` /
  `SetHideMessageFunction` / `SetQuitFunction` / `SetSystemUpdateFunction` /
  `GetCapslockState` / `GetMode`。
  **其中没有任何一条携带内核/启动日志。**【已核实】

⇒ **本项目的结论**：三行滚动文本**继续用插件自带的 console viewer**（它已经在显示内核消息了），
我们只需要**给它加"视口 + 行数"配置**（一行 C 改动），而不是重新发明一条日志通路。
规格见 `theme/viewport-patch-spec.md`。

### 2.4 现成的 4 个主题配置键【已核实】

`src/plugins/splash/script/plugin.c:229-243`：

| 键（`[script]` 组） | 默认值 | 作用 |
|---|---|---|
| `MonospaceFont` | `monospace 10` | console viewer 字体。**注释原文**："Likely only able to set the font if the font is in the initrd" |
| `ConsoleLogTextColor` | `PLY_CONSOLE_VIEWER_LOG_TEXT_COLOR` = **`0xffffffff`**（白） | 日志文字色，`0xRRGGBBAA` |
| `ConsoleLogBackgroundColor` | `0x00000000`（全透明） | 日志区底色 |
| `ImageDir` / `ScriptFile` | — | 主题目录与脚本路径 |

另有 `[script-env-vars]` 组：`create_plugin()` 行 227 `ply_key_file_foreach_entry()` 收集，
`start_script_animation()` 行 327-335 在执行主题脚本**之前**注入为全局变量。**这是我们传参的通道。**

### 2.5 字体必须存在于 initramfs【已核实】

```
$ lsinitramfs /boot/initrd.img-$(uname -r) | grep -iE 'fonts|pango'
etc/fonts/conf.d/60-latin.conf
etc/fonts/fonts.conf
usr/share/fonts/truetype/ubuntu/UbuntuMono-Italic[wght].ttf
usr/share/fonts/truetype/ubuntu/UbuntuMono[wght].ttf
usr/share/fonts/truetype/ubuntu/Ubuntu[wdth,wght].ttf
```
⇒ **只能写 `Ubuntu Mono` / `Ubuntu`**（`Cantarell` 是 PyPI 之外的东西，**不在 initramfs 里**，
stock `spinner.plymouth` 写 `Cantarell 12` 在 initramfs 阶段是会静默回退的）。
`label-pango.so`（pango+cairo+fontconfig 实现）已在 initramfs 中，所以文字渲染可用。

---

## 问题 3 — `script` 插件实际可用的对象与函数

【已核实】来源：平板 `script.so` 的 `strings`，与上游源码 `script-lib-{sprite,image,math,string,plymouth}.*` 交叉比对。

### 3.1 对象

| 对象 | 可用成员 | 说明 |
|---|---|---|
| **`Image`** | `Image(filename)`、`Image.Text(text, red, green, blue[, alpha[, font[, align]]])`、`GetWidth()`、`GetHeight()`、`Scale(w,h)`、**`Rotate(angle)`**、`Crop(x,y,w,h)`、`Tile(w,h)`、`Adopt(raw)` | **没有独立的 `Text` 对象**，文字用 `Image.Text` 生成位图。`red/green/blue/alpha` 是 **0..1 浮点**；`align` ∈ `"left"/"center"/"right"`（`script-lib-image.c:183-260`） |
| **`Sprite`** | `Sprite([image])`、`SetImage`、`GetImage`、`GetX/SetX`、`GetY/SetY`、`GetZ/SetZ`、`GetOpacity/SetOpacity`、`SetPosition(x,y,z)` | `SetPosition` 是 `script-lib-sprite.script` 里的封装 |
| **`Window`** | `GetWidth`、`GetHeight`、`GetX/SetX`、`GetY/SetY`、`SetBackgroundTopColor(r,g,b)`、`SetBackgroundBottomColor(r,g,b)` | **没有 `Window` 级别的旋转** |
| **`Math`** | `Math.Pi`、`Abs`、`Clamp`、`Int`、`Max`、`Min`、`Sin`、`Cos`、`Tan`、`ATan2`、`Sqrt` | |
| **`Plymouth`** | 见 §2.3 的 18 个回调 | 无内核日志相关 |

**没有** `ConsoleViewer` 对象、**没有** `Image.Rotate` 之外的全局旋转变换。

### 3.2 语言能力【已核实】

* 变量、`fun name(a,b){...}`、`if/else`、`while`、`do-while`、`for`、`break`、`continue`。
* 运算符：`+ - * / %`、`+= -= *= /= %=`、`== != < > <= >=`、`&& || !`、`++ --`、
  `|`（`SCRIPT_EXP_TYPE_EXTEND`）、`|=`（`SCRIPT_EXP_TYPE_ASSIGN_EXTEND`）。
  **`/`（除法）存在**：`script-parse.c` 的 `operator_table` 里 `{ "/", SCRIPT_EXP_TYPE_DIV, 6 }`【已核实】。
* **数组字面量** `[ a, b, c ]` 与下标 `arr[i]`：上游 `themes/script/script.script` 用 `dialog.bullet[index]` 作证。
* **点号对象**：`a.b = v` 给 hash 加键，`a.b` 读。可用来做命名空间（上游参考主题大量使用）。
* **全局/局部**：`global.x`、`local.x`。
* **`Plymouth.SetUpdateStatusFunction` 的回调会收到 `status`/`mode` 字符串**。
* 主题脚本主流程执行**早于**第一帧绘制，因此 sprite 在脚本顶层创建即可。

### 3.3 字号 / 颜色 / 多行队列

| 需求 | 能否做到 | 怎么做 |
|---|---|---|
| 设置字号、颜色 | ✅ | `Image.Text(text, r, g, b, a, "Ubuntu Mono 24")`；console viewer 用 `MonospaceFont` + `ConsoleLogTextColor` |
| 多行队列滚动 | ✅（但不在脚本层） | console viewer 原生滚动（§2.2 第 4 步）；脚本层可以自己做（见下） |
| `SetUpdateFunction` | ⚠️ 不叫这个名字 | 等效的是 **`Plymouth.SetRefreshFunction(fun(){...})`** + `Plymouth.SetRefreshRate(n)`，参考主题就是用它做闪烁动画的 |

**脚本层自己实现"三行队列"是可行的**（备用方案）：
用 `global.lines = [NULL, NULL, NULL]`，`SetDisplayMessageFunction` 收消息，把三个 `Image.Text` 依次
上移一行重新 `SetImage`。**但这条路只能收到 `plymouth display-message`，收不到内核日志**，
所以**不满足用户需求**，只作为"想显示自定义阶段提示"时的扩展点。

---

## 问题 4 — ★ 屏幕方向问题

### 4.1 硬件与内核现状【已核实】

```bash
$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'fbcon|simpledrm|console'
modprobe.blacklist=simpledrm
fbcon=rotate:1
consoleblank=0
loglevel=4
```
```bash
$ cat /sys/class/drm/card1-DSI-1/status ; cat /sys/class/drm/card1-DSI-1/modes
connected
1600x2560          # 面板原生竖屏，唯一模式
$ cat /sys/class/drm/card1-DSI-1/enabled ; cat /sys/class/drm/card1-DSI-1/dpms
enabled
On
$ ls /sys/class/graphics/fb0/ ; cat /sys/class/graphics/fb0/name /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/stride
msmdrmfb
1600,2560
6400
$ cat /sys/class/graphics/fbcon/rotate
1
$ ls /sys/class/drm/card1-DSI-1/
connector_id  device  dpms  edid  enabled  modes  power  status  subsystem  uevent
                # ^^^ 只有通用属性，没有独立的 properties/ 目录
$ modetest
bash: modetest: 未找到命令
```

面板驱动与方向：`grep -c 'set_panel_orientation' drivers/gpu/drm/panel/panel-himax-hx83121a.c` = **0**；
`panel-orientation-quirks.c` 里 **没有** Huawei/gaokun/Matebook 条目。
内核配置：`CONFIG_FRAMEBUFFER_CONSOLE_ROTATION=y`、`CONFIG_DRM_FBDEV_EMULATION=y`、`CONFIG_FB=y`。

### 4.2 plymouth 用的是 **DRM 渲染器**，且**忽略** fb0【已核实】

在平板上用一个**独立的 `plymouthd` 实例**（`--no-daemon --debug --tty=/dev/tty63`，
私有 socket，不干扰正在运行的 plymouthd）跑出来的日志：

```
../src/libply-splash-core/ply-renderer.c:247:ply_renderer_open : trying to open renderer plugin .../renderers/drm.so
../src/plugins/renderers/drm/plugin.c:990:load_driver  : drm driver: msm
../src/plugins/renderers/drm/plugin.c:1160:get_preferred_mode : Found preferred mode 1600x2560 at index 0
../src/plugins/renderers/drm/plugin.c:587:ply_renderer_head_ad: Adding connector with id 36 to 1600x2560 head
../src/plugins/renderers/drm/plugin.c:635:ply_renderer_head_ne: Creating 1600x2560 renderer head
../src/libply-splash-core/ply-device-manager.c:1019:create_pix: Adding displays for 1 heads
...
../src/libply-splash-core/ply-device-manager.c:397:create_devi: found frame buffer device /dev/fb0
../src/libply-splash-core/ply-device-manager.c:245:fb_device_h: trying to find associated drm node for fb device (path: platform-ae01000.display-controller)
../src/libply-splash-core/ply-device-manager.c:403:create_devi: ignoring, since there's a DRM device associated with it
```

**逐条结论**：
1. 打开的是 `drm.so`，驱动 `msm`，head = **1600×2560（竖屏原生）**。
2. `/dev/fb0` 被显式 **`ignoring, since there's a DRM device associated with it`** ⇒
   **Framebuffer 渲染器根本没被使用**。
3. **没有任何旋转日志**（没有 `Keeping hw 180° rotation`，也没有 `panel orientation` 分支）。
4. 源码交叉验证：`src/plugins/renderers/frame-buffer/plugin.c` 里
   **`grep -i rotat` 零命中** ⇒ 即使强制 framebuffer 渲染器，它**也不支持旋转**。
5. `src/plugins/renderers/drm/plugin.c:497-538`：DRM 渲染器唯一的旋转来源是 connector 的
   **`panel orientation`** 属性；本机 connector **没有该属性**（面板驱动没调 `drm_connector_set_panel_orientation`，
   也没有 DMI quirk）⇒ `output->rotation = PLY_PIXEL_BUFFER_ROTATE_UPRIGHT`。

### 4.3 ★ 会不会侧躺？**会。**【已核实（机制）+ 推测（方向）】

* `fbcon=rotate:1` 只影响 **VT 控制台（fbcon）**把字符画进 framebuffer 的方式，
  与 DRM plane 无关。plymouth 直接画 DRM plane ⇒ **完全绕开它**。
* 因此 plymouth 渲染的 "上" 是 **scanout 的 +Y 方向**，而这在物理玻璃上**不是真正的上**
  ⇒ **LOGO 会侧躺 90°**。
* **方向**：`fbcon=rotate:1` = `FB_ROTATE_CW`（`include/uapi/linux/fb.h:236`），
  即"把控制台内容顺时针转 90° 后放进 framebuffer"。
  ⇒ 要得到同样（当前可读的）效果，plymouth 必须**顺时针转 90°**。
  这是**推测**（未做视觉确认），所以主题把角度做成**一个可切换常量**：`RotateQuadrant=1`
  （顺时针）/ `3`（逆时针），**第一次上机时按 §4.5 的 A/B 流程二选一**。

### 4.4 备选方案对比

| 方案 | 改动面 | 评价 |
|---|---|---|
| **A. 主题内自旋转**（**采用**） | 只改 plymouth 主题 | ✅ 不动内核、不动 mutter、风险最低。本主题的 `RotateQuadrant` 就是它 |
| B. 给面板驱动加 `drm_connector_set_panel_orientation(connector, DRM_MODE_PANEL_ORIENTATION_LEFT_UP)` | 内核（面板驱动 + 可能加 DMI quirk） | ⚠️ 一次性解决 plymouth **和** fbcon 的朝向（`panel orientation` 由 DRM 渲染器行 537-538 消费），但会同时影响 mutter/gnome 的旋转推断 ⇒ **需回归 GNOME 显示方向**，本轮不做 |
| C. 强制 framebuffer 渲染器 + 预旋转图片 | cmdline + 资源 | ❌ 无意义：fb 渲染器**不支持旋转**，而且 plymouth 在没有 fbdev 时更不稳 |
| D. 预旋转资源 | 只改图片 | ❌ 只能修 LOGO，**修不了 console viewer 的文字**（pango 标签没有旋转接口）；且方向仍是猜的 |

**⇒ 采用 A**：`Image.Rotate()` 是脚本唯一可用的旋转手段，主题对**每张图**旋转后按旋转坐标系摆放。

### 4.5 ★ 上机 A/B 判定流程（不靠猜）

```
# 1. 装上主题，重启。
# 2. 看 LOGO：如果"开口朝上"正常 -> RotateQuadrant 正确；
#    如果歪 90° -> 把 gaokun3-splash.plymouth 里的 RotateQuadrant 1 <-> 3 互换，重跑 update-initramfs + 重启。
# 3. 文字如果也歪 90°，说明文字同样需要旋转 —— 这只能由 §2 的 console viewer 补丁解决
#    （pango 标签无法在脚本层旋转），补丁里给 ply_console_viewer_draw_area() 加同样的旋转即可。
# 4. 文字位置：console viewer 的 viewport 坐标是 **scanout 坐标**（未旋转），
#    "屏幕上看起来的左下角" = scanout 的 (x 小, y 大) = (48, 2560-3*font_height-48)。
```

> ⚠️ 因为**平板当前不可重启**（本调研全程只读），`RotateQuadrant` 的最终取值必须由主代理
> 在实机上做上面这一步确认。**这是本报告唯一未闭环的推测项。**

---

## 问题 5 — 需要的 cmdline / 配置项

### 5.1 ★ plymouthd 起不来的硬门槛：`splash`【已核实】

`/usr/lib/systemd/system/plymouth-start.service`：
```ini
[Unit]
ConditionKernelCommandLine=!plymouth.enable=0
ConditionKernelCommandLine=!nosplash
ConditionKernelCommandLine=splash            # <=== 必须
ConditionVirtualization=!container
[Service]
ExecStart=/usr/sbin/plymouthd --mode=boot --pid-file=/run/plymouth/pid --attach-to-session
ExecStartPost=-/usr/bin/plymouth show-splash
```

`src/daemon/plymouthd-policy.c::plymouthd_should_show_default_splash()`：
```c
if (ply_kernel_command_line_has_argument ("splash")) {
        ply_trace ("using default splash because kernel command line has option \"splash\"");
        return true;
}
...
ply_trace ("no default splash because kernel command line lacks \"splash\" or \"rhgb\"");
return false;
```

⇒ **不加 `splash`，`plymouth-start.service` 直接被 Condition 干掉，什么都不显示**（当前就是这个状态）。

### 5.2 ★ `quiet` 要不要加？**不要**【已核实 + 推理】

* 不需要：`should_show_default_splash()` 只看 `splash` / `rhgb` / `splash=silent`，**不看 `quiet`**。
* 不应该加：内核 printf 的级别由 `loglevel=` 控制；`quiet` 只是把 **console_loglevel 设为 4**
  （等价于 `loglevel=4`，本机**已经有了**）。去掉 `quiet` 不会让屏幕更吵 —— 当前 `loglevel=4`
  已经过滤掉 `<4` 的消息（注意"4"就是 KERN_WARNING 本身，会打印）。
* **反过来**：一旦 `splash` + `--attach-to-session` 生效，plymouthd 会把控制台输出重定向进自己的日志
  （`--attach-to-session  Redirect console messages from screen to log`），
  屏幕上看到的就是 **plymouth 的 console viewer（我们的三行区）**，而不是裸 tty0 滚动。

### 5.3 最小改动清单

| 项 | 改动 | 位置 | 影响评估 |
|---|---|---|---|
| ① cmdline 加 `splash` | 只加到**我们自己的 BLS 条目** | `/boot/efi/loader/entries/<machine-id>-<KVER>.conf` 的 `options=` | 触发 plymouth 启动。**不动 `loader.conf` 默认项、不动 EFI 变量** |
| ② 装主题 | 新增 `/usr/share/plymouth/themes/gaokun3-splash/{*.plymouth,*.script,logo.png}` | 新目录 | 只新增文件，不覆盖任何现存主题 |
| ③ 选主题 | 写 `/etc/plymouth/plymouthd.conf` 的 `[Daemon] Theme=gaokun3-splash` | 该文件当前只有注释（无有效组） | 需要**备份原文件**以便回滚。**不要**用 `plymouth-set-default-theme`（未安装） |
| ④ 重建 initramfs | `update-initramfs -u -k <KVER>` | — | **必须**，否则 initramfs 里没有 `script.so`（§1.3） |
| ⑤ 可选：`plymouth.ignore-serial-consoles` | 不加 | — | 本机 `systemctl cat plymouth-start.service` 已带 `--attach-to-session`，无串口控制台，不需要 |

**保留不动**：`loglevel=4`、`consoleblank=0`、`fbcon=rotate:1`、`modprobe.blacklist=simpledrm`、
`iommu.*`、`psi=1`、`systemd.machine_id=...`。

### 5.4 会不会影响现有能用的东西

| 现有能力 | 影响 | 依据 |
|---|---|---|
| EL1 启动 / slbounce 判定 | **无**（cmdline 只加一个 `splash`，DTB 不变） | §5.3 只改 `options=` 追加一个词 |
| venus 硬解 | **无**（与显示初始化无关） | — |
| 触屏 60 s 空闲策略 | **无**（`splash` 不影响触屏驱动；`fbcon=rotate:1` 保留） | — |
| GPU 遥测 | **无** | — |
| VT 控制台可读性 | **无**（`fbcon=rotate:1` 保留，plymouth 退出后 VT 仍是横屏可读） | §4.3 |
| 启动可见性 | **改善**：以前满屏 dmesg，现在三行视口 | 需求本身 |
| 启动时间 | plymouthd 在 `loglevel=4` 下几乎零开销；console viewer 每 1/60 s 一次重绘 | `TERMINAL_OUTPUT_UPDATE_INTERVAL (1.0/60)` |

**风险点**：如果主题脚本有语法错误，plymouth 会走 §6 的回退链（**不会黑屏、不会卡住启动**）。

---

## 问题 6 — 失败回退与安全实测

### 6.1 四级回退链【已核实】

`src/daemon/plymouthd-display.c:200-260`（`plymouthd_show_default_splash()`）：

```
1. override_splash_path            （plymouthd.conf [Daemon] Theme= 或 cmdline）
2. system_default_splash_path      （/etc/alternatives/default.plymouth 解析结果）
3. distribution_default_splash_path
4. PLYMOUTH_THEME_PATH "default.plymouth"        <- "Trying old scheme for default splash"
5. PLYMOUTH_THEME_PATH "text/text.plymouth"      <- "Could not start default splash screen, showing text splash screen"
6. show_theme (daemon, NULL)                     <- "showing built-in splash screen"（内建兜底）
```

`plymouthd_load_splash()`（`src/daemon/plymouthd-splash.c:116-150`）在 `!is_loaded` 时
`ply_boot_splash_free(splash); return NULL;` ⇒ 上层拿到 NULL 继续往下一级试。

**⇒ 答案：不会黑屏。** 回退顺序是 `text` 主题（在 **VT 上用文字**画进度）→ 内建兜底。
**注意**：回退到 `text` 时**看不到内核日志**（text 插件只画 "3 box countdown"），
但启动过程仍然可见（能选盘、能看到进度、按 ESC 有反馈）。

### 6.2 `details` 与 `text` 的区别（容易搞混）

* `details` = **文本插件**，把 boot buffer 直接 `ply_terminal_write()` 到 **VT 终端**
  （`src/plugins/splash/details/plugin.c:193-225, 271-321`），**不是图形渲染**。
  它没有旋转、没有 sprite，内容就是满屏原始日志 —— 也就是"现在看到的样子"。
* `text` = 文字主题 + 3 格倒计时，用于密码/问题等场景。

### 6.3 ★ 如何安全实测"主题写坏"而不变砖

**先讲为什么安全**【已核实】：
* plymouthd 不接管显示所有权（DRM master 会在退出时释放），
* `plymouth-quit.service` 在 GNOME 起来之前 `plymouth quit`，
* ssh 已 enabled（`systemctl is-enabled ssh` → `enabled`），
* **只有加了 `splash` 的那一条 BLS 条目**受影响，默认条目与其它内核条目不带 `splash` ⇒
  在 systemd-boot 菜单里选别的条目就能回到"满屏日志"的现状。

**推荐实测顺序（从零风险到全风险）**：

```bash
# 步骤 0（零风险）：只装主题、不改 cmdline。
#   plymouthd 根本不会启动（没有 splash），所以不可能因此变砖。
#   验证：重生成 initramfs 后，用独立实例验证主题能否加载（不碰运行中的 display）：
sudo unshare -m --propagation private bash -c '
  mkdir -p /run/plymouth
  cp /usr/share/plymouth/plymouthd.defaults /run/plymouth/plymouthd.defaults
  timeout 10 /usr/sbin/plymouthd --no-daemon --debug \
      --debug-file=/tmp/ply-test.log --kernel-command-line="splash" \
      --mode=boot --tty=/dev/tty63'
grep -iE 'executing script file|parsing script file|error|fail|not found' /tmp/ply-test.log
#   ^ 本报告就是用这个办法在【不改系统配置】的前提下验证主题加载路径的。
#     注意：要真正让 plymouthd 加载我们指定的主题，用 mount namespace 遮蔽配置：
sudo unshare -m --propagation private bash -c '
  mount --bind /path/to/test-plymouthd.conf /etc/plymouth/plymouthd.conf
  timeout 10 /usr/sbin/plymouthd --no-daemon --debug \
      --debug-file=/tmp/ply-test.log --kernel-command-line="splash" --mode=boot'
#   （卸载 namespace 后 /etc/plymouth/plymouthd.conf 原样未动）

# 步骤 1（低风险）：故意把 .script 写坏（例如删掉一个 }），重生成 initramfs，
#   然后用【我们自己的 BLS 条目】重启（不要动默认条目）。
#   预期：屏幕出现 text 主题（文字进度），系统照常进 GNOME，ssh 正常。
#   取证：plymouthd 是 --attach-to-session，日志走 boot log，
#         可用 dmesg / journalctl -b 查 "Could not start default splash screen"。

# 步骤 2（低风险）：故意把 ModuleName 写成不存在（ModuleName=doesnotexist）。
#   预期：同上，回退 text。

# 步骤 3（兜底）：若不幸完全无显示，systemd-boot 菜单选【默认条目】（不带 splash），
#   或从仓库里已有的其它内核条目启动；仍然可用就 ssh 进去用 --uninstall 回滚。
```

**回滚**：
```bash
# 1) 还原 /etc/plymouth/plymouthd.conf（安装时备份为 .gaokun3-splash.bak）
sudo cp /etc/plymouth/plymouthd.conf.gaokun3-splash.bak /etc/plymouth/plymouthd.conf
# 2) 从我们自己的 BLS 条目 options= 里去掉 "splash"
# 3) sudo update-initramfs -u -k <KVER>
# 4) sudo rm -rf /usr/share/plymouth/themes/gaokun3-splash
```

---

## 交付物与主代理落地清单

### 已产出（`%TEMP%\splash\`）

| 文件 | 说明 |
|---|---|
| `RESEARCH.md` | 本报告 |
| `theme/gaokun3-splash.plymouth` | 主题描述；`ModuleName=script`；`[script]` 字体/颜色；`[script-env-vars]` 参数 |
| `theme/gaokun3-splash.script` | 居中 LOGO + 旋转补偿；**不画日志**（日志由插件 console viewer 负责） |
| `theme/logo.png` | 512×512 自有 LOGO（sha256 `1b2bd044…`），可替换资源 |
| `theme/logo.svg` | LOGO 矢量源 |
| `theme/make-logo.ps1` | 从 svg 规则重绘 png 的生成脚本（Windows `System.Drawing`，无第三方依赖） |
| `theme/viewport-patch-spec.md` | ★ 三行视口 + 行数的 C 改动规格（含精确行号与替换代码） |

### 主代理要做的 4 件事（按顺序）

1. **先做 §6.3 步骤 0**：把主题装到平板、`update-initramfs`、用 `unshare -m` 的独立 plymouthd
   验证脚本能被解析执行（**此时 cmdline 还没有 `splash`，零风险**）。
2. **确认方向**：给 BLS 条目加 `splash`，重启，按 §4.5 判定 `RotateQuadrant` 取 1 还是 3。
3. **落脚本阶段目标达成**：此时屏幕上应有"居中 LOGO + 满屏日志"（因为 console viewer 默认全屏）。
4. **要"三行左下角"就必须上 C 补丁**（`viewport-patch-spec.md`）：
   建议**不要**给 plymouth 打 distro 补丁，而是把 `ply-console-viewer.[ch]` + `script/plugin.c`
   的相关片段 **fork 进本仓库**（`drivers/plymouth/`），自己构建 `script.so` 替换进
   `/usr/lib/aarch64-linux-gnu/plymouth/` **并且** 用 `/etc/initramfs-tools/hooks/` 钩子把它塞进 initramfs。
   ⚠️ 该 `.so` 与 distro 包版本绑定，**必须在文档里写清 plymouth 版本**，并在 `--uninstall` 里还原原 `.so`
   （安装脚本先 `cp -a` 备份原始 `script.so`）。

### 尚缺 / 待验证（诚实标注）

* 【推测】`RotateQuadrant` 的最终取值（顺/逆时针 90°）—— 需实机一眼确认（§4.5）。
* 【未做】console viewer 的文字旋转 —— 若 §4.5 第 3 步发现文字也歪，补丁里要一并给
  `ply_console_viewer_draw_area()` 加旋转（本次未展开到那个粒度）。
* 【未做】`script.so` 的实际重编译与替换流程（本调研为只读，未在平板编译）。
* 【未做】把 `logo.png` 塞进 initramfs 的钩子（`/usr/share/initramfs-tools/hooks/`）——
  Ubuntu 自带的 plymouth hook 只拷当前主题目录，如果我们的主题成为 `default.plymouth` 的目标就会自动带上；
  若走 `plymouthd.conf Theme=` 覆盖路径，**需要确认 hook 是否也会拷**（`update-alternatives default.plymouth` 才是
  hook 的取值来源，见 `/usr/share/initramfs-tools/hooks/plymouth` 第 15-17 行）⇒ **建议安装脚本顺带
  `update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth
  /usr/share/plymouth/themes/gaokun3-splash/gaokun3-splash.plymouth 200`**，
  并在回滚时 `--remove`。这一点**需实机验证 hook 行为**。
