# 研究记录

[English](research.md) · [操作步骤](procedure.zh-CN.md) · [返回 README](../README.zh-CN.md)

本篇以实测的 `PKG6.6230` → `PKG6.5086` 为例，记录旧固件怎么进到槽里、进去之后为什么
起不来，以及怎么让它起来。

方法本身不绑定这两个版本。操作序列见[操作步骤](procedure.zh-CN.md)。

---

## 结果

`PKG6.6230`（Android 10）→ `PKG6.5086`（Android 9），活动槽 `_a`，`verifiedbootstate=orange`。

未拆机、未用 eMMC 编程器、未用 UART。

---

## 旧固件怎么进槽

设备是 A/B 双槽。降级时旧固件要写进当前没在跑的那个槽，有两条路。

**分区级写入。** 把固件包解开，得到每个分区的镜像，逐个写进非活动槽：

```
固件包 .zip
  └── payload.bin                 A/B OTA 载荷
        └── 解包 → boot.img / system.img / vendor.img / dtbo.img / ...
```

解锁之后 `fastboot flash` 就能做这件事。

**走更新服务提交。** 设备本身带一个网络下载服务，给它一个地址，它去取 OTA 包并安装。
这条路会走完整的安装链：校验、写槽、跑安装后的脚本。本次用的就是这条。6.5086 是这样
进到槽 A 的，安装日志里 2024/2024 个操作全部成功，收尾是
`onPayloadApplicationComplete(errorCode=0)`。

两条路都只是把镜像放进槽。**放进去了不等于能启动**，那是下面几节的事。

---

## 为什么降不了

先看两个值：

```
vbmeta.rollback_index (6.5086)  =  16050861000636
RPMB 里的 stored_rollback_index =  16062301000725

判据：16050861000636 < 16062301000725
     →  AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX
     →  avb_ab_flow 把槽标记为 unbootable
     →  换槽启动
```

两个数来自固件包版本号。RPMB 里那个是被一次自动 OTA 升级（6.6188 → 6.6230）抬上去的，
从用户态改不了。

`ALLOW_VERIFICATION_ERROR` 也救不了：

```c
if (ret == AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX) {
    /* Even with AVB_SLOT_VERIFY_FLAGS_ALLOW_VERIFICATION_ERROR
     * these mean game over. */
    set_slot_unbootable = true;
}
```

### 走更新通道也不行

每一条前端更新路径都要过 `isNewerThanRunningVersion()`，它把版本相同或更低的包拒掉。
把原始 6.5086 内层 ZIP 从设备的特权更新通道递进去，返回的是：

```json
{"result": false, "code": 3}
```

日志显示包解析正常、`isValidTarget()` 通过，唯一失败的是 `isNewerThanRunningVersion()`。

---

## 破法

RPMB 那一侧动不了，但 `vbmeta_a` 可以换。替换用的 vbmeta 需要满足三个条件：

| 字段 | 取值 | 作用 |
| --- | --- | --- |
| `rollback_index` | `16062301000725`（与当前**相等**） | 判据 `stored < stored` 为假，不报回滚错误。取相等而非极大值，是因为 `avb_ab_flow` 会把当前槽索引写回 RPMB，设大值会造成不可逆影响 |
| `flags` | `2`（VERIFICATION_DISABLED） | 第 1412 行据此提供 `root=PARTUUID=$(ANDROID_SYSTEM_PARTUUID)`；U-Boot 的 bootargs 里没有 `root=` |
| descriptors | 无 | 原 vbmeta 的 6 个 `Chain Partition` 各有独立回滚索引（location 1/3/4/5/6/7） |

签名用自生成的 RSA2048，故意让它"不可信"。

因为 `avb_ab_flow.c:295` 对 `ERROR_PUBLIC_KEY_REJECTED` 的处理是：

```c
case AVB_SLOT_VERIFY_RESULT_ERROR_PUBLIC_KEY_REJECTED:
    if (flags & AVB_SLOT_VERIFY_FLAGS_ALLOW_VERIFICATION_ERROR) {
        saw_and_allowed_verification_error = true;   // 放行
    } else {
        set_slot_unbootable = true;
    }
```

而生产构建确实置位了该 flag（`CC_ANDROID_SECURE_BOOT_CLASS_B` 在 `env.mk` 中定义）。

⇒ 未受信的签名恰恰是被放行的那一类，所以不需要伪造原始签名。

### 写回这一点值得单独说

`avb_ab_flow` 在启动流程末尾会把索引写回 RPMB：

```c
if (ab_data.slots[slot_index_to_boot].successful_boot
    && current_rollback_index_value != rollback_index_value)
{
    io_ret = ops->write_rollback_index(ops, n, rollback_index_value);
}
```

两个条件同时成立才写：该槽已标记成功启动，**且两边索引不相等**。

所以索引取"相等"有两个作用：让判据成立，同时让写回无事可做。填别的值，要么判据不成立，
要么把 RPMB 永久抬高。

触发时机取决于 `successful_boot`，不是第几次重启。刚刷进去的槽它是清的，要等 Android
起来调 `markBootSuccessful()`。

---

## 关键突破：fastboot 可以从软件进入

这是整个方案成立的前提。要写 `vbmeta_a` 就得进 fastboot，而进 fastboot 要有人往 `misc`
分区写标志。但写 `misc` 本身就是一次 eMMC 写，看起来是循环的。

**其实不用自己写，内核会写。**

### 内核写标志

```c
// board/mt5893/module/pdwnc_hw.c:1319 — 编译进 dtv_driver.ko
if(event == SYS_RESTART) {
    if(cmd && !x_memcmp(cmd, "bootloader", 10)) {
        msdc_partwrite_byname("misc", 512, sizeof("fastboot"), "fastboot");
    }
}
```

### 引导器读标志

```c
// board/mt5893/mt5893_board.c — BIM_CheckFastboot()
emmc_read_from_partition(pmisc_msg, "misc", 512, size);
if(strcmp(pmisc_msg->command, "fastboot")==0)  return 1;
```

### 引导器照做

```c
// common/main.c — 调用点
if (BIM_CheckFastboot()) {
    udc_init(&surf_udc_device);
    if (fastboot_init() == 0) {
        udc_start();
        watchdog_disable();
        fastboot_command_loop();
    }
}
```

⇒ 从 Android 执行 `reboot bootloader`，内核把 `"fastboot"` 写进 `misc[512]`，下次启动
U-Boot 读到就进 fastboot。

**旁证：`dtv_driver.ko` 里 `bootloader` / `fastboot` / `recovery` / `boot-recovery`
四个字符串紧邻，顺序与源码一致。**

### 解锁命令

```c
// common/download_command.c — do_flashing()
else if (strcmp("unlock", TempData) == 0) {
    fastboot_info("wipe user data");
    EraseUserData();
    setenv("devicestate", TempData);
    saveenv();
}
```

⇒ `fastboot flashing unlock`，代价是清用户数据。

### 端口与线材

| 环节 | 结论 | 依据 |
| --- | --- | --- |
| 用哪个 USB 口 | **USB 2.0**（不是 3.0） | USB 3.0 挂在 `mt53xx-xhci`（纯主机）；只有 `TVUSB20` 带 gadget |
| gadget 端口号 | **端口 1** | `env.mk: USB_ADB_PORT=1` → `MUSB_GADGET_PORT_NUM=1` |
| 线的方向 | **电脑必须是主机** | 实测：普通 C 转 A 线让 Mac 变成从设备（电视认到 `Apple Inc. Mac`），方向反了 |
| 可用接法 | 扩展坞（或 C 转 A 母口 OTG 头）+ USB-A 公对公线 | 实测扩展坞方案一次成功 |

---

## 数据清除的坑

先看现象：刷完 vbmeta 后必须清 `/data`（Android 10 → 9，旧数据库版本更高，新系统读不了）。
三种方式里前两种都错了。

| 做法 | 结果 |
| --- | --- |
| `fastboot erase userdata` | **耗时 0.05 秒 —— 只是发了 TRIM（惰性擦除），数据一个字节没动** |
| 往 userdata 开头写 1 GB 零 | 耗时 36 秒（真写了），文件系统元数据被砸烂 → 但 Android **不会自动格式化** → 卡在开机动画 17 分钟以上 |
| **硬件恢复出厂** | 由 loader 执行真正的格式化 → 系统正常启动 |

### 为什么"写零"是错的

| | 写 1 GB 零 | 硬件恢复出厂 |
| --- | --- | --- |
| 对文件系统做的事 | 破坏（superblock 等元数据被清零） | 重新格式化（生成有效的空文件系统） |
| Android 看到的状态 | 无法挂载 | 可正常挂载 |
| Android 的反应 | **既挂不上、又不自动格式化 → 死锁** | 直接挂载 → 正常启动 |

当时的假设是"破坏文件系统 → Android 会自动重新格式化"，这个假设是错的。

### 硬件恢复出厂

```
① 拔掉电视电源线，等约 30 秒
② 按住电视机身上的【电源键】+【音量减键】（不是遥控器）
③ 保持按住的同时，把电源线插回去
④ 继续按住，直到屏幕出现 logo —— 那时才松手
⑤ 等 3~10 分钟（屏幕会显示 "erasing"）
```

关键：这个流程由待机 MCU 处理，**在 Android 启动之前就工作**，所以即使 Android 完全起不来
也能触发。

实测：屏幕依次显示 `erasing` → 重启 → 欢迎向导，数据被正确格式化。

