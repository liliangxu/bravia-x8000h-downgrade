# 研究记录

[English](research.md) · [操作步骤](procedure.zh-CN.md) · [返回 README](../README.zh-CN.md)

本篇以实测的 `PKG6.6230` → `PKG6.5086` 为例，记录旧固件怎么进到槽里、进去之后为什么
起不来，以及怎么让它起来。

方法本身不绑定这两个版本。操作序列见[操作步骤](procedure.zh-CN.md)。

下面引用的代码都标了文件路径和行号，可以在对应版本的源码包里核对。都是逐字摘录，只做了
两件事：把整块代码的缩进左移到适合摘录的位置，以及把略去的行换成 `...`。

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

`payload.bin` 不是压缩包，要用专门的 A/B payload 解包工具（如 `payload-dumper-go`）
才能取出各分区镜像。解锁之后 `fastboot flash` 就能把它们写进槽。

**走更新服务提交。** 设备本身带一个网络下载服务，给它一个地址，它去取 OTA 包并安装。
这条路会走完整的安装链：校验、写槽、跑安装后的脚本。本次用的就是这条。6.5086 是这样
进到槽 A 的，安装日志里 2024/2024 个操作全部成功，收尾是
`onPayloadApplicationComplete(errorCode=0)`。

两条路都只是把镜像放进槽。**放进去了不等于能启动**，那是下面几节的事。

---

## 为什么降不了

先看两个值：

```
6.5086 镜像的 rollback_index  =  16050861000636
6.6230 镜像的 rollback_index  =  16062301000725

判据：16050861000636 < 16062301000725
     →  AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX
     →  avb_ab_flow 把槽标记为 unbootable
     →  换槽启动
```

两个数都是从**固件镜像**里读出来的，对应包版本号。

设备上实际存的那个值读不到，RPMB 从用户态不可访问。这里按最后安装过的版本推断：
自动 OTA 升到 6.6230 之后，存的值应当是 6.6230 的索引。后面第 0 步用的是这个推断值，
而替换之后能启动，与推断一致。

`ALLOW_VERIFICATION_ERROR` 也救不了：

```c
/* lib/libavb_ab/avb_ab_flow.c:282 */
case AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX:
case AVB_SLOT_VERIFY_RESULT_ERROR_INVALID_METADATA:
case AVB_SLOT_VERIFY_RESULT_ERROR_UNSUPPORTED_VERSION:
  /* Even with AVB_SLOT_VERIFY_FLAGS_ALLOW_VERIFICATION_ERROR
   * these mean game over.
   */
  set_slot_unbootable = true;
  break;
```

判据本身在验证器里：

```c
/* lib/libavb/avb_slot_verify.c:675 */
if (vbmeta_header.rollback_index < stored_rollback_index) {
  avb_errorv(
      full_partition_name,
      ": Image rollback index is less than the stored rollback index.\n",
      NULL);
  ret = AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX;
  if (!allow_verification_error) {
    goto out;
  }
}
```

### 走更新通道也不行

本次尝试的普通更新入口都要过 `isNewerThanRunningVersion()`，它把版本相同或更低的包拒掉。
把原始 6.5086 内层 ZIP 从设备的特权更新通道递进去，返回的是：

```json
{"result": false, "code": 3}
```

日志显示包解析正常、`isValidTarget()` 通过，唯一失败的是 `isNewerThanRunningVersion()`。

---

## 破法

RPMB 那一侧动不了，但 `vbmeta_a` 可以换。替换用的 vbmeta 有两处必须对：

| 字段 | 取值 | 作用 |
| --- | --- | --- |
| `rollback_index` | `16062301000725`，取自当前镜像 | 拒绝条件是镜像索引低于存值。取当前镜像的值让判据成立，同时不把存值抬高（前提是设备存值与当前镜像一致）；`avb_ab_flow` 会把当前槽索引写回 RPMB，设大值会造成不可逆影响 |
| `flags` | `2`（VERIFICATION_DISABLED） | 第 1412 行据此提供 `root=PARTUUID=$(ANDROID_SYSTEM_PARTUUID)`；U-Boot 的 bootargs 里没有 `root=` |

实测时还没有放 descriptors。原 vbmeta 有 6 个 `Chain Partition`，各有独立回滚索引
（location 1/3/4/5/6/7）；`flags=2` 已经跳过 descriptor 处理，所以这不是通过判据的另一个
前提，只是当时生成的镜像就是空的。

签名用自生成的 RSA2048，故意让它"不可信"。

因为 `avb_ab_flow.c:292` 对 `ERROR_PUBLIC_KEY_REJECTED` 的处理是：

```c
/* lib/libavb_ab/avb_ab_flow.c:292 */
case AVB_SLOT_VERIFY_RESULT_ERROR_VERIFICATION:
case AVB_SLOT_VERIFY_RESULT_ERROR_PUBLIC_KEY_REJECTED:
  if (flags & AVB_SLOT_VERIFY_FLAGS_ALLOW_VERIFICATION_ERROR) {
    /* Do nothing since we allow this. */
    avb_debugv("Allowing slot ", ...);
    saw_and_allowed_verification_error = true;
  } else {
    set_slot_unbootable = true;
  }
  break;
```

而生产构建确实置位了该 flag（`CC_ANDROID_SECURE_BOOT_CLASS_B` 在 `env.mk` 中定义）。

⇒ 未受信的签名恰恰是被放行的那一类，所以不需要伪造原始签名。

### 写回这一点值得单独说

`avb_ab_flow` 在启动流程末尾会把索引写回 RPMB：

```c
/* lib/libavb_ab/avb_ab_flow.c:404 */
if (ab_data.slots[slot_index_to_boot].successful_boot
  && current_rollback_index_value != rollback_index_value) {
  io_ret = ops->write_rollback_index(ops, n, rollback_index_value);
  ...
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
/* board/mt5893/module/pdwnc_hw.c:1324 */
if(event == SYS_RESTART)
{
    #ifdef CC_ANDROID_FASTBOOT_SUPPORT
    if(cmd && !x_memcmp(cmd, "bootloader", 10))
    {
        int u4Val = msdc_partwrite_byname("misc",512,sizeof("fastboot"),(void *)"fastboot");
        if(u4Val == -1)
        LOG(0,"\n writer misc partition failed \n");
    }
    #endif
    ...
}
```

### 引导器读标志

```c
/* board/mt5893/mt5893_board.c:1343 */
INT32 BIM_CheckFastboot(void)
{
    misc_message *pmisc_msg;
    ...
    pmisc_msg = memalign(DCACHE_LINE_SIZE,size);
    ...
    emmc_read_from_partition((unsigned char*)pmisc_msg, "misc", 512, size);
    ...
    if(strcmp(pmisc_msg->command, "fastboot")==0)
    {
        ...
        return 1;
    }
    ...
}
```

### 引导器照做

```c
/* common/main.c:437 */
if (BIM_CheckFastboot())
{
    char *newstr;
    newstr = env_add_usb_serialno();
    surf_udc_device.serialno = newstr;
    udc_init(&surf_udc_device);
    if (fastboot_init() == 0)
    {
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
/* common/download_command.c:646 */
else if (strcmp("lock", TempData) == 0 || strcmp("unlock", TempData) == 0)
{
    if (dev_state != NULL && strcmp(dev_state, TempData) != 0)
    {
        fastboot_info("wipe user data");
        EraseUserData();
        setenv("devicestate", TempData);
        saveenv();
    }
}
```

⇒ `fastboot flashing unlock` 走的就是这个分支。它把清除用户数据的请求写进 `misc`，
具体见下面数据清除那一节。

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
| `fastboot erase userdata` | 约 0.05 秒返回；之后开机的表现和没跑过这条命令一样 |
| 往 userdata 开头写 1 GB 零 | 耗时 36 秒（真写了），文件系统元数据被砸烂 → 但 Android **不会自动格式化** → 卡在开机动画 17 分钟以上 |
| **硬件恢复出厂** | 系统正常启动 |

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

实测：即使 Android 完全起不来，这组按键仍然触发了恢复出厂；屏幕依次显示 `erasing`、
重启、欢迎向导。

---

## 降级后的待机卡死

电视降级后能正常开机，也能播放视频。问题出在待机之后：有时按遥控器叫不醒，机身电源键
也没反应，等一会儿电视又会自己重启。重新开机后看起来一切正常，偶尔还能成功唤醒一次。

我最初沿着 HDMI ARC 和音频服务往下查。后来抓到一个关键状态：音频编码器已经收到了
停止请求，但工作线程一直没有退出。

### 音频线程在等谁

卡住时，几层调用分别停在这些地方：

| 位置 | 正在等什么 |
| --- | --- |
| `android.hardware.drm@1.1-service.widevine` | `OEMCrypto_Initialize LoadUsage` 中发往 `com.android.trusty.widevine` 的 `0x1442` 请求，正在等回复 |
| `/vendor/lib/libmtal.so` | 音频编码器线程在 `MTAUDDEC_GetDolbyEfuse` 中等共享的 Trusty 事务信号量 |
| `dtv_driver.ko` | 已经设置停止标志，等待 CPU 音频编码器线程退出 |
| `dtv_svc` | 音频配置调用持有组件锁，电源回调等这把锁 |
| `system_server` | 等同步的 Power HAL `setInteractive` 调用返回 |

把它们接起来，原因就清楚了。Widevine 拿着共享信号量，等可信服务回复；音频编码器要做
Dolby 初始化，也需要这个信号量。等到待机或唤醒流程要求编码器停下来，线程却退不出去，
电源回调跟着堵住。最后 Android watchdog 超时，结束 `system_server`，电视重新启动。

这也解释了为什么有时第一次唤醒成功，下一次才卡。原来的编码器线程还正常，可以顺利退出；
唤醒后新建的线程才堵在共享信号量上，下一次切换电源状态时就暴露出来了。

我做了两组对照。开机时，在 Widevine 开始初始化之前停掉两个服务入口，连续三轮待机／
唤醒都成功。之后用标准 MediaDrm 初始化并查询 `securityLevel`，同一笔可信服务请求和
信号量等待再次出现；接下来停止编码器时又卡住，最终触发 watchdog 重启。

这些状态是在诊断系统中通过 root ADB 读取的，音频库和 framework 代码保持原版。
直接抓到的最内层状态是 Widevine 在等待可信服务回复，后面的音频和电源阻塞链已经串起来了。

### 让 Widevine 直接走 L3

Widevine 是视频服务使用的一套 DRM。L1 走硬件可信执行环境，L3 走软件路径。

解锁引导器后，Verified Boot 变成 `orange`。L1 依赖可信启动链和受保护的密钥处理，
[AOSP 早期的 Widevine 集成说明](https://android.googlesource.com/platform/docs/source.android.com/+/idea133-weekly-release/src/devices/drm.jd)里有这部分要求。
解锁后的系统不再提供原有的启动验证保证，因此这里使用软件 L3，不再依赖出厂状态下的
L1 能力。L1 不可用时，正常预期是回退到仍可工作的 L3，而不是整个 DRM 服务卡住。

这次遇到的不只是失去 L1。故障那次查询在 21:01:12.350 打出了
`L3 Initialized. Trying L1.`，紧接着 21:01:12.366 就进入了
`OEMCrypto_Initialize LoadUsage`。软件 L3 已经初始化成功，但适配层随后继续尝试
L1，卡在了前面那笔可信服务请求上。L1 初始化没有返回，也就没能正常结束初始化并
确定使用 L3，连 `securityLevel` 查询都没有返回。

我在 Android 9 的原版库里找到了一个现成的启动开关：`FORCE_LEVEL3_OEMCRYPTO=yes`。

这个开关同时存在于 `/vendor/lib/libwvhidl.so` 和旧接口使用的
`/vendor/lib/mediadrm/libwvdrmengine.so`。设置之后，适配层在 L3 初始化成功后就结束
初始化，不再继续尝试 L1/OEMCrypto。两个 DRM 服务都可能加载 Widevine，所以两处
启动配置都要加。

实际改动是给两个服务的 init 配置各加一行 `setenv`。重新生成 `vendor.img` 后，只刷入
`vendor_a`，下次开机由 init 正常启动原来的服务。库文件、服务身份和 SELinux 域都没有
改动。具体文件和镜像处理方法见[操作步骤](procedure.zh-CN.md#处理待机卡死)。

改完后，`ro.boot.verifiedbootstate` 仍然是 `orange`，表示引导器保持解锁。
`green`／`orange` 说的是启动验证状态，L1／L3 说的是 Widevine 的 DRM 路径。
这次改变的是 Widevine 的启动方式，启动验证状态没有变化。属性的定义可以对照
[AOSP 启动流程说明](https://source.android.com/docs/security/features/verifiedboot/boot-flow)。

### L3 下的播放情况

持久化配置刷入后，我做了两次独立启动，每次都通过标准 MediaDrm 接口查到了 `L3`。
第一次启动连续测了十轮待机／唤醒，第二次又测了三轮。13 轮都正常完成，采样时音频编码器
没有再等那把 Trusty 信号量，也没有新增 watchdog 或自行重启。最后 ARC 已建立，
系统音频处于启用状态。

实际播放的 4K 视频也正常。DRM 等级和视频分辨率是两回事，选择 L3 后，视频解码器仍然
照常工作。在线视频能拿到什么画质，还要看平台的授权策略：要求硬件 DRM 的服务可能在
L3 下限制清晰度，或拒绝播放。这部分行为在 Android 的
[`MediaDrm.openSession(int)` 文档](https://developer.android.com/reference/android/media/MediaDrm#openSession(int))里有说明。

上面的连续测试覆盖了启动、L3 等级查询和待机唤醒。HDR、DD+／Atmos 播放以及长期使用，
还需要另外做播放测试。

