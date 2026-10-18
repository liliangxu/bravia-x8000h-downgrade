# 操作步骤

[English](procedure.md) · [研究记录](research.zh-CN.md) · [返回 README](../README.zh-CN.md)

这套步骤照搬了实际跑通的那一次。换固件组合没有测过。

重点在第 0 步（生成替换用 vbmeta）和第 8 步（硬件恢复出厂）。中间刷写那几步都是标准
fastboot 操作。

---

## 需要什么

- 设备能正常启动 Android，网络 ADB 已授权
- 电脑上有 `adb`、`fastboot`、`openssl`、Python 3，以及 `avbtool`
- 一份比设备当前版本旧的完整固件包（见[固件从哪来](#固件从哪来)）
- 一根**数据** USB 线，接设备的 **USB 2.0** 口；电脑侧要是主机（见
  [研究记录](research.zh-CN.md#端口与线材)）
- 用户数据已备份。流程里有两次清数据

下面所有命令在电脑上执行。只连一台设备。

---

## 固件从哪来

固件包从设备的 OTA 分发服务器取，不在支持页面。支持页面只列当前版本。

### 完整 OTA 包

```
https://tv-update.sony.com.cn/OND/<年份>/as/ch/<目录标识>/sony_atvotafull_2018_<版本号>_cna_auth.zip
```

各段含义：

| 段 | 含义 |
| --- | --- |
| `OND` | OTA 分发路径 |
| `<年份>` | 该目录挂上去的年份，**不代表包的发布年份** |
| `as/ch` | 区域：亚洲 / 中国 |
| `<目录标识>` | 形如 `PS215299`，见下 |
| `sony_atvotafull_2018_<版本号>_cna_auth.zip` | 完整包名 |

包名里的三段：

| 段 | 含义 |
| --- | --- |
| `sony_atvotafull_2018` | 固定前缀 |
| `<版本号>` | 10 位十进制。取该版本回滚索引的前 10 位，例如 `16050861000636` → `1605086100` |
| `cna` | 区域后缀：`cna` 中国、`naa` 北美、`paa`、`eua` 欧洲 |

### 目录标识

这段不参与包名，只决定放哪个目录。它的规律：

- **与版本号没有对应关系**，也没有公开的定义
- **同一个版本常挂在多个目录下**，同一个目录下也会放多个版本
- **编号相近的目录服务同一批包**。同一时期、不同区域的包，编号是挨着的
- **目录年份和包名里的 `2018` 可以不一致**

所以实际的找法：

1. 包名可以先拼出来。知道版本号就知道文件名
2. 区域后缀按目标改，几个都试
3. 目录标识靠已知地址反查。从任一还能打开的旧包地址里读出来
4. 编号相邻的目录一起试

另有一个不带目录的扁平路径，可以先用它确认包名拼对了：

```
https://tv-update.sony.com.cn/URL_archive/zip/sony_atvotafull_2018_<版本号>_cna_auth.zip
```

### 引导器源码（不是固件）

```
https://oss.sony.net/Products/Linux/TV/KD-65A9F_Asia_Ver66230.html
```

对应 U-Boot 源码包 49,312,462 字节，MD5 `d1ecfa04477150694b3dac47390563e9`。本文引用的
源码路径都以它为准。**它和固件包是两回事**：源码用来核对逻辑，固件才是要写进设备的东西。

### 可获取性

CDN 上的历史版本会被清理。如果某个版本的包已经拿不到，就换一个比当前版本旧、且能拿到
完整包的版本。方法不绑定某一个旧版本，第 0 步的做法对哪个版本都一样，索引都取自设备
当前运行的版本。不过只在上面那组固件上验证过，换版本时分区布局、更新组件和引导器的
行为是否一致，需要自行确认。

---

## 0. 生成替换用 vbmeta

**这一步最容易出错，而且后果最重。**

先从**设备当前运行版本**的固件包里取出 `vbmeta.img`，读出它的回滚索引：

```bash
export AVBTOOL=/absolute/path/to/avbtool.py

bash tools/inspect-vbmeta.sh vbmeta_current.img
# 记住输出里的 Rollback Index
```

**是当前版本，不是要装进去的旧版本。** 拒绝条件是镜像索引低于设备存值，取旧版本的值会
被挡下。采用当前镜像的值可以让判据成立，同时不把存值抬高，前提是设备存值与当前镜像
一致。设备实际存的值没有直接读过，这一点见[研究记录](research.zh-CN.md#为什么降不了)。

**这个值也不能猜。** 填大了会把 RPMB 永久抬高，填小了会被拒绝启动。

然后生成替换头：

```bash
bash tools/make-vbmeta.sh <上面读到的索引> vbmeta_patched.img
bash tools/inspect-vbmeta.sh vbmeta_patched.img
```

生成结果应当显示：

| 字段 | 期望值 |
| --- | --- |
| Algorithm | `SHA256_RSA2048` |
| Flags | `2` |
| Descriptors | 无 |
| 大小 | 8192 字节 |
| Rollback Index | 与你从当前固件读到的值相等 |

实测那台机器跑的是 6.6230，从它的镜像读到 `16062301000725`，仅供参考格式。**不要照抄这个数字。**

生成新密钥会让镜像哈希变化，核对上面这些字段即可。

---

## 1. 把旧固件装进槽

设备有两个槽，同一时刻只有一个在运行。先看当前在哪个：

```bash
adb shell getprop ro.boot.slot_suffix
```

返回 `_a` 或 `_b`。**旧固件要写进另一个槽**：当前是 `_b` 就写 A，是 `_a` 就写 B。

写进正在运行的那个槽，会破坏当前可用的系统。所以这里用的是非活动槽。

这一步有两个做法，本文不展开：

- **用 `fastboot flash` 逐个写分区。** 解锁后可以写 `boot_a`、`system_a`、`vendor_a`、
  `dtbo_a`、`linux_rootfs_a`、`3rd_a`、`recipe_a` 等。后缀用非活动槽的那个。
  **⚠️ 不要碰 `uboot`（永久保护）、`upgrade`（loader 更新落点）、`eeprom_A`。**
- **走设备自带的更新服务提交。** 两条路各是怎么工作的，见
  [研究记录](research.zh-CN.md#旧固件怎么进槽)。

**两条路都只是把镜像放进槽，都不会让旧固件启动。** 让它可以启动是第 3 步往下的事。

---

## 2. 进 fastboot

```bash
adb connect <设备IP>:5555
adb shell reboot bootloader
fastboot devices
```

期望看到一行以 `fastboot` 结尾。什么都没有就是 USB 那层不对，先按
[研究记录](research.zh-CN.md#端口与线材) 排查。屏幕会是黑的，正常。

---

## 3. 解锁

```bash
fastboot flashing unlock
```

解锁会提交清除用户数据的请求，但命令返回成功不代表格式化已经完成，后面第 8 步仍要恢复
出厂。不做这步，后面的 `flash` 会被拒：`device locked, forbid to write flash.`

---

## 4. 写入替换用 vbmeta

```bash
fastboot flash vbmeta_a vbmeta_patched.img
```

`vbmeta_a` 里的 `a` 是**第 1 步写的那个槽**，不是当前运行的那个。写成 `vbmeta_b` 就
对应 B 槽。第 6 步跟着改。期望看到 `OKAY` 和字节数。

---

## 5. 清除 fastboot 标志

```bash
fastboot erase misc
```

`erase misc` 会连 A/B 元数据一起清掉，所以**必须在设置槽位之前做**。不做这步，下次普通
重启又会掉回 fastboot。

---

## 6. 设置活动槽

```bash
fastboot set_active a
```

把活动槽切到**第 1 步写入的那个槽**，也就是第 4 步写 `vbmeta` 用的同一个后缀。

---

## 7. 重启

```bash
fastboot reboot
```

**上面六条命令实测全部返回 `OKAY`，整串跑完不到 1 秒。**

设备开始启动旧固件。首次启动比较久。

---

## 8. 硬件恢复出厂

**这一步不能省，也不能用软件方式代替。**

不要用 `fastboot erase userdata` 顶替。这条命令约 0.05 秒就返回，之后开机的表现和没跑过
一样，没有解决后续启动的问题。

```
① 拔掉电视电源线，等约 30 秒
② 按住电视机身上的【电源键】+【音量减键】（不是遥控器）
③ 保持按住的同时，把电源线插回去
④ 继续按住，直到屏幕出现 logo —— 那时才松手
⑤ 等 3~10 分钟（屏幕会显示 "erasing"）
```

为什么必须这么做，见 [研究记录](research.zh-CN.md#数据清除的坑)。

---

## 9. 验证

```bash
adb connect <设备IP>:5555
adb shell getprop ro.build.version.incremental    # 应当是你装进去那个包的版本
adb shell getprop ro.boot.slot_suffix             # 应当是你选的槽
adb shell getprop ro.boot.verifiedbootstate       # 期望 orange
adb shell getprop sys.boot_completed              # 期望 1
```

前两项对着你实际装的包和选的槽看。`verifiedbootstate` 是 `orange`，表示引导器处于已解锁
状态，与本次操作后的状态一致；它不能单独说明替换的镜像正在生效。

`tools/check-state.sh` 会把这些属性连同系统版本、型号、vbmeta 状态一次打出来。它只读，
不执行任何包管理、设置修改、重启或分区写入命令。

---

## 处理待机卡死

这里给原有的两个 Widevine 服务配置软件 L3 路径。卡住的 L1 调用怎样拖住音频和电源流程，
见[研究记录](research.zh-CN.md#降级后的待机卡死)。

输入文件用电视当前所装固件解出的原版 raw `vendor.img`。电视已经完成降级，引导器保持
解锁，使用前面生成的关闭验证的 vbmeta。下面以旧系统正在运行的槽 A 为例。

电脑上另外需要 e2fsprogs 的 `debugfs`、`e2fsck`，Android libsparse 的 `img2simg`、
`simg2img`，以及 `avbtool` 能调用的 Android `fec`，后者要在 `PATH` 中。
`AVBTOOL` 沿用第 0 步设置的路径，下列镜像处理命令均在电脑上执行。

### 准备镜像，取出配置

把解出的原版镜像留作 `vendor.original.img`。在本地建一个 `vendor-work/` 目录，后面
只修改工作副本 `vendor.img`。

```bash
# 电脑端文件：vendor-work/vendor.original.img、vendor-work/vendor-avb.txt
mkdir vendor-work
cp /path/to/extracted/vendor.img vendor-work/vendor.original.img
cd vendor-work
shasum -a 256 vendor.original.img
python3 "$AVBTOOL" info_image --image vendor.original.img > vendor-avb.txt
```

从这份 vendor 镜像里读出分区大小、回滚索引和 salt。重建 footer 时保留 vendor 自己的
这些参数；前面替换用的顶层 vbmeta 有它自己的回滚索引，两处分别处理。

```bash
# 电脑端输入：vendor-work/vendor-avb.txt
vendor_size=$(awk '/^Image size:/ {print $3}' vendor-avb.txt)
vendor_index=$(awk '/^Rollback Index:/ {print $3}' vendor-avb.txt)
vendor_salt=$(awk '/^[[:space:]]*Salt:/ {print $2}' vendor-avb.txt)
```

取出两个 init 配置。镜像内路径从 `/etc` 开始，装到电视上后才是 `/vendor/etc`。

```bash
# 电脑端输出：vendor-work/widevine-1.1.rc、vendor-work/drm-1.0.rc
debugfs -R 'dump /etc/init/android.hardware.drm@1.1-service.widevine.rc widevine-1.1.rc' vendor.original.img
debugfs -R 'dump /etc/init/android.hardware.drm@1.0-service.rc drm-1.0.rc' vendor.original.img
```

编辑 `widevine-1.1.rc`，在 Widevine 服务下面加一行。文件前面的数据迁移服务保持原样。

```diff
--- /vendor/etc/init/android.hardware.drm@1.1-service.widevine.rc
+++ /vendor/etc/init/android.hardware.drm@1.1-service.widevine.rc
 service vendor.drm-widevine-hal-1-1 /vendor/bin/hw/android.hardware.drm@1.1-service.widevine
+    setenv FORCE_LEVEL3_OEMCRYPTO yes
     class hal
```

`drm-1.0.rc` 中也加上同一行：

```diff
--- /vendor/etc/init/android.hardware.drm@1.0-service.rc
+++ /vendor/etc/init/android.hardware.drm@1.0-service.rc
 service vendor.drm-hal-1-0 /vendor/bin/hw/android.hardware.drm@1.0-service
+    setenv FORCE_LEVEL3_OEMCRYPTO yes
     class hal
```

### 写回配置，重建镜像

这两份原始配置各占一个 4096 字节的数据块，加完一行之后仍然放得下。
先在自己的镜像里查出块号，并核对修改后的文件大小：

```bash
# 镜像内路径：/etc/init/android.hardware.drm@1.1-service.widevine.rc
#             /etc/init/android.hardware.drm@1.0-service.rc
debugfs -R stats vendor.original.img
rc11_block=$(debugfs -R 'blocks /etc/init/android.hardware.drm@1.1-service.widevine.rc' vendor.original.img | xargs)
rc10_block=$(debugfs -R 'blocks /etc/init/android.hardware.drm@1.0-service.rc' vendor.original.img | xargs)
printf 'Widevine block: %s\nLegacy DRM block: %s\n' "$rc11_block" "$rc10_block"
wc -c widevine-1.1.rc drm-1.0.rc
```

确认块大小是 4096、每个块号输出只有一个整数、两个修改后的文件都小于 4096 字节。
然后把内容写进原来的数据块，再更新 inode 中的文件大小。这样沿用原 inode，权限和
SELinux 标签也保留下来。

```bash
# 电脑端工作镜像：vendor-work/vendor.img
cp vendor.original.img vendor.img
python3 "$AVBTOOL" erase_footer --image vendor.img
dd if=widevine-1.1.rc of=vendor.img bs=4096 seek="$rc11_block" conv=notrunc
dd if=drm-1.0.rc of=vendor.img bs=4096 seek="$rc10_block" conv=notrunc
debugfs -w -R "sif /etc/init/android.hardware.drm@1.1-service.widevine.rc size $(wc -c < widevine-1.1.rc)" vendor.img
debugfs -w -R "sif /etc/init/android.hardware.drm@1.0-service.rc size $(wc -c < drm-1.0.rc)" vendor.img
e2fsck -fn vendor.img
```

再把镜像里的文件导出，与编辑后的配置比较。`stat` 输出里的 mode、UID/GID 和
`security.selinux` 应保留原来的值。

```bash
# 电脑端核对文件：vendor-work/widevine-1.1.check.rc、vendor-work/drm-1.0.check.rc
debugfs -R 'dump /etc/init/android.hardware.drm@1.1-service.widevine.rc widevine-1.1.check.rc' vendor.img
debugfs -R 'dump /etc/init/android.hardware.drm@1.0-service.rc drm-1.0.check.rc' vendor.img
cmp widevine-1.1.rc widevine-1.1.check.rc
cmp drm-1.0.rc drm-1.0.check.rc
debugfs -R 'stat /etc/init/android.hardware.drm@1.1-service.widevine.rc' vendor.img
debugfs -R 'stat /etc/init/android.hardware.drm@1.0-service.rc' vendor.img
```

按原 vendor 的参数重建 hashtree、FEC 和 footer，然后转成 sparse 镜像：

```bash
# 电脑端工作镜像：vendor-work/vendor.img
python3 "$AVBTOOL" add_hashtree_footer --image vendor.img \
  --partition_name vendor --partition_size "$vendor_size" \
  --hash_algorithm sha1 --salt "$vendor_salt" --fec_num_roots 2 \
  --algorithm NONE --rollback_index "$vendor_index" \
  --internal_release_string 'avbtool 1.1.0'
python3 "$AVBTOOL" verify_image --image vendor.img
python3 "$AVBTOOL" info_image --image vendor.img
img2simg vendor.img vendor-l3.sparse.img 4096
simg2img vendor-l3.sparse.img vendor-roundtrip.img
cmp vendor.img vendor-roundtrip.img
shasum -a 256 vendor.original.img vendor.img vendor-l3.sparse.img
```

重建结果中的 `Algorithm` 为 `NONE`，这份修改后的镜像配合现有关闭验证的顶层 vbmeta
使用，引导器继续保持解锁。

### 刷入 vendor，检查下次启动

这次修改的是已经在运行旧系统的那个槽。按下面的例子操作前，确认 Android 和 fastboot
报告的都是 A，再写 `vendor_a`。

```bash
# 电脑端输入：vendor-work/vendor-l3.sparse.img；电视端目标：vendor_a
adb shell getprop ro.boot.slot_suffix
adb reboot bootloader
fastboot getvar current-slot
fastboot -S 120M flash vendor_a vendor-l3.sparse.img
fastboot reboot
```

这一步只写 `vendor_a`，保留原来的槽位选择、vbmeta 和用户数据。
`-S 120M` 将单次传输控制在实测设备 128 MiB 的下载上限以内。

网络 ADB 连回来后，检查启动和两个服务：

```bash
# 电视端状态：init 服务、/proc/sys/kernel/random/boot_id
adb connect <device-ip>:5555
adb shell getprop sys.boot_completed
adb shell getprop init.svc.vendor.drm-widevine-hal-1-1
adb shell getprop init.svc.vendor.drm-hal-1-0
adb shell cat /proc/sys/kernel/random/boot_id
adb shell getprop ro.boot.verifiedbootstate
adb shell dumpsys dropbox
```

前五项依次应是 `1`、`running`、`running`、本次启动的 boot ID、`orange`。
用能显示 Widevine `securityLevel` 的应用确认 `L3`，再按平时的声音输出方式播放视频，
连续做几轮待机／唤醒，核对 boot ID 和 watchdog 条目的时间。之后正常重启一次，
再测一轮，确认配置由 init 在新的一次启动中自动生效。

我在第一次启动测了十轮，第二次测了三轮；4K 播放情况一起记在
[研究记录](research.zh-CN.md#l3-下的播放情况)中。恢复原配置时，把保留的
`vendor.original.img` 刷回同一个 vendor 分区即可。

---

## 回到原来的固件

```bash
adb shell reboot bootloader
fastboot erase misc
fastboot set_active <另一个槽>
fastboot reboot
```

顺序和第 5、6 步一致：先清 `misc`，再选槽。然后同样用组合键再做一次恢复出厂。

**这一节没有实测过**，只是按正向流程的规则反推出来的。

---

## 需要避免的操作

| | |
| --- | --- |
| `fastboot flashing lock` | 修改后的元数据不应配合重新锁定使用 |
| `fastboot flash uboot ...` | 错误刷写引导器可能导致无法启动，恢复方法未验证 |
| 用 `fastboot erase userdata` 当清数据 | 约 0.05 秒返回，但没有解决后续启动问题 |
| 往 `userdata` 写零 | Android 既不挂载也不格式化 |
| 往活动槽写旧固件 | 破坏当前可用的系统 |
| 跳过第 8 步 | 旧系统读不了新的用户数据 |
| 让设备重新联网升级 | 后续 OTA 可能覆盖替换的元数据，影响降级后的启动 |

