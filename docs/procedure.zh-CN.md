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
https://oss.sony.net/Products/Linux/TV/<机型页>.html
```

这里发布的是 GPL 源码包，U-Boot 约 49 MB。本文引用的源码路径都以它为准。**它和固件包
是两回事**：源码用来核对逻辑，固件才是要写进设备的东西。

### 可获取性

CDN 上的历史版本会被清理。如果某个版本的包已经拿不到，就换一个比当前版本旧、且能拿到
完整包的版本。方法本身和版本无关：换哪个旧版本，第 0 步的做法都一样，索引都取自设备
当前运行的版本。

---

## 0. 生成替换用 vbmeta

**这一步最容易出错，而且后果最重。**

先从**设备当前运行版本**的固件包里取出 `vbmeta.img`，读出它的回滚索引：

```bash
export AVBTOOL=/absolute/path/to/avbtool.py

bash tools/inspect-vbmeta.sh vbmeta_current.img
# 记住输出里的 Rollback Index
```

**是当前版本，不是要装进去的旧版本。** RPMB 里存的是设备上出现过的最高版本索引，
替换头必须与它相等。取旧版本的值会被判据挡下。

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

实测那台机器读到的索引是 `16062301000725`，仅供参考格式。**不要照抄这个数字。**

生成新密钥会让镜像哈希变化，核对上面这些字段即可。

---

## 1. 把旧固件装进槽

设备有两个槽，同一时刻只有一个在运行。先看当前在哪个：

```bash
adb shell getprop ro.boot.slot_suffix
```

返回 `_a` 或 `_b`。**旧固件要写进另一个槽**：当前是 `_b` 就写 A，是 `_a` 就写 B。

写进正在运行的那个槽，等于把系统换成旧版本，而它的元数据还是新的。重启后判据不成立，
旧系统起不来；两个槽都成了新的，没有可回退的地方。

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

**这一步会清空用户数据。** 不做这步，后面的 `flash` 会被拒：
`device locked, forbid to write flash.`

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

不要用 `fastboot erase userdata` 顶替。这条命令在这个平台上只发 TRIM，数据一个字节
没动。

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

前两项对着你实际装的包和选的槽看。`verifiedbootstate` 是 `orange` 就说明验证已关闭、
用的是替换后的元数据。

`tools/check-state.sh` 会把这些属性连同系统版本、型号、vbmeta 状态一次打出来。它只读，
不执行任何包管理、设置修改、重启或分区写入命令。

---

## 回到原来的固件

```bash
adb shell reboot bootloader
fastboot set_active <另一个槽>
fastboot erase misc
fastboot reboot
```

然后同样用组合键再做一次恢复出厂。用户数据对不上这件事，两个方向都会发生。

---

## 会把设备搞坏的操作

| | |
| --- | --- |
| `fastboot flashing lock` | 之后 `erase misc` 会被拒，就出不来 fastboot 了 |
| `fastboot flash uboot ...` | 破坏引导器签名，永久变砖 |
| 用 `fastboot erase userdata` 当清数据 | 只发 TRIM，数据还在 |
| 往 `userdata` 写零 | Android 既不挂载也不格式化 |
| 往活动槽写旧固件 | 覆盖正在运行的系统，且没有可回退的槽 |
| 跳过第 8 步 | 旧系统读不了新的用户数据 |
| 让设备重新联网升级 | OTA 会立刻扑上来，把降级成果抹掉 |

