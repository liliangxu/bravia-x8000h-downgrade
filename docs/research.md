# Research notes

[简体中文](research.zh-CN.md) · [Procedure](procedure.md) · [README](../README.md)

These notes use the measured `PKG6.6230` → `PKG6.5086` case to work through how the older
firmware gets into a slot, why it would not start once it was there, and what made it start.

The method is not tied to those two versions. The steps themselves are in the
[procedure](procedure.md).

---

## Result

`PKG6.6230` (Android 10) → `PKG6.5086` (Android 9), active slot `_a`,
`verifiedbootstate=orange`.

No disassembly, no eMMC programmer, no UART.

---

## Getting the older firmware into a slot

The device has two slots. A downgrade means writing the older firmware into whichever slot
is not currently running. Two ways to do that.

**Partition-level writes.** Unpack the firmware package into per-partition images and write
them one by one into the inactive slot:

```
package .zip
  └── payload.bin                 the A/B OTA payload
        └── unpacked → boot.img / system.img / vendor.img / dtbo.img / ...
```

`fastboot flash` can do this once the device is unlocked.

**Submission through the update service.** The device carries a network download service:
hand it an address and it fetches the OTA package and installs it. This route runs the whole
chain: verification, writing the slot, post-install scripts. It is the one used here. 6.5086
reached slot A that way, with 2024/2024 operations succeeding in the install log and
`onPayloadApplicationComplete(errorCode=0)` at the end.

Both routes only put the image in the slot. **Being in the slot is not the same as being
bootable**, which is what the rest of this note is about.

---

## Why it would not boot

Two values first:

```
vbmeta.rollback_index (6.5086)  =  16050861000636
stored_rollback_index in RPMB   =  16062301000725

test:  16050861000636 < 16062301000725
    →  AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX
    →  avb_ab_flow marks the slot unbootable
    →  the other slot is tried
```

Both numbers come from firmware package versions. The RPMB one was raised by an automatic
update (6.6188 → 6.6230) and cannot be lowered from userspace.

`ALLOW_VERIFICATION_ERROR` does not help either:

```c
if (ret == AVB_SLOT_VERIFY_RESULT_ERROR_ROLLBACK_INDEX) {
    /* Even with AVB_SLOT_VERIFY_FLAGS_ALLOW_VERIFICATION_ERROR
     * these mean game over. */
    set_slot_unbootable = true;
}
```

### The update path is not a way back either

Every front-end update route runs `isNewerThanRunningVersion()`, which rejects a package
whose version is the same as or lower than the running build. Submitting the original
6.5086 inner ZIP through one of the device's privileged update channels returned:

```json
{"result": false, "code": 3}
```

The log showed the package parsed correctly and `isValidTarget()` passed; the only failing
check was `isNewerThanRunningVersion()`.

---

## The way around it

The RPMB side cannot be touched, but `vbmeta_a` can be replaced. The replacement satisfies
three conditions:

| Field | Value | Effect |
| --- | --- | --- |
| `rollback_index` | `16062301000725`, **equal** to the current value | The test `stored < stored` is false, so no rollback error is raised. Equal rather than maximal, because `avb_ab_flow` writes the slot's index back to RPMB, and a large value would have irreversible effects |
| `flags` | `2` (VERIFICATION_DISABLED) | Line 1412 uses this to supply `root=PARTUUID=$(ANDROID_SYSTEM_PARTUUID)`; U-Boot's own bootargs carry no `root=` |
| descriptors | none | The original vbmeta's six `Chain Partition` entries each carry their own rollback index (locations 1/3/4/5/6/7) |

The signature comes from a locally generated RSA-2048 key, untrusted on purpose.

`avb_ab_flow.c:295` handles `ERROR_PUBLIC_KEY_REJECTED` like this:

```c
case AVB_SLOT_VERIFY_RESULT_ERROR_PUBLIC_KEY_REJECTED:
    if (flags & AVB_SLOT_VERIFY_FLAGS_ALLOW_VERIFICATION_ERROR) {
        saw_and_allowed_verification_error = true;   /* allowed */
    } else {
        set_slot_unbootable = true;
    }
```

The production build sets that flag (`CC_ANDROID_SECURE_BOOT_CLASS_B` is defined in
`env.mk`).

So an untrusted signature is exactly the kind that gets allowed. No original signature
needs to be forged.

### Note the write-back

`avb_ab_flow` writes the index back to RPMB at the end of the boot flow:

```c
if (ab_data.slots[slot_index_to_boot].successful_boot
    && current_rollback_index_value != rollback_index_value)
{
    io_ret = ops->write_rollback_index(ops, n, rollback_index_value);
}
```

Both conditions have to hold: the slot is marked successfully booted, **and** the two
indices differ.

That is why the index is set equal: it satisfies the test and leaves the write-back with
nothing to do. Any other value either fails the test or raises the RPMB value permanently.

When it fires depends on `successful_boot`, not on a fixed number of reboots. A freshly
flashed slot has it clear until Android starts and calls `markBootSuccessful()`.

---

## The key finding: fastboot can be entered from software

This is the premise the whole approach rests on. Writing `vbmeta_a` requires fastboot, and
entering fastboot requires something to write a marker into the `misc` partition — which is
itself an eMMC write. It looks circular.

It is not: the marker does not have to be written by hand. **The kernel writes it.**

### The kernel writes the marker

```c
// board/mt5893/module/pdwnc_hw.c:1319 — compiled into dtv_driver.ko
if(event == SYS_RESTART) {
    if(cmd && !x_memcmp(cmd, "bootloader", 10)) {
        msdc_partwrite_byname("misc", 512, sizeof("fastboot"), "fastboot");
    }
}
```

### The bootloader reads it

```c
// board/mt5893/mt5893_board.c — BIM_CheckFastboot()
emmc_read_from_partition(pmisc_msg, "misc", 512, size);
if(strcmp(pmisc_msg->command, "fastboot")==0)  return 1;
```

### And acts on it

```c
// common/main.c
if (BIM_CheckFastboot()) {
    udc_init(&surf_udc_device);
    if (fastboot_init() == 0) {
        udc_start();
        watchdog_disable();
        fastboot_command_loop();
    }
}
```

So `reboot bootloader` from Android makes the kernel write `"fastboot"` to `misc[512]`, and
the next boot of U-Boot reads it and enters fastboot.

**Corroboration: in `dtv_driver.ko` the four strings `bootloader`, `fastboot`, `recovery`
and `boot-recovery` sit adjacent and in the same order as the source.**

### The unlock command

```c
// common/download_command.c — do_flashing()
else if (strcmp("unlock", TempData) == 0) {
    fastboot_info("wipe user data");
    EraseUserData();
    setenv("devicestate", TempData);
    saveenv();
}
```

So `fastboot flashing unlock`, at the cost of erasing user data.

### Port and cable

| Item | Finding | Basis |
| --- | --- | --- |
| Which USB port | **USB 2.0**, not 3.0 | USB 3.0 hangs off `mt53xx-xhci` (host only); only `TVUSB20` has a gadget |
| Gadget port number | **port 1** | `env.mk: USB_ADB_PORT=1` → `MUSB_GADGET_PORT_NUM=1` |
| Cable direction | **the computer must be the host** | measured: a plain C-to-A cable made the Mac a device (the TV reported an `Apple Inc. Mac`), i.e. the wrong direction |
| Working connection | dock (or C-to-A female OTG adapter) + USB-A male-to-male | the dock arrangement worked first try |

---

## Clearing userdata

The context: after flashing vbmeta, `/data` has to be erased, because Android 10 → 9 means
the newer database is unreadable by the older system. Three approaches were tried; the
first two were wrong.

| Approach | Result |
| --- | --- |
| `fastboot erase userdata` | **takes 0.05 s — it only issues a TRIM; not one byte of data moved** |
| writing 1 GB of zeros at the start of userdata | takes 36 s (so the write really happens); the filesystem metadata is destroyed → Android **does not reformat** → stuck on the boot animation for over 17 minutes |
| **hardware factory reset** | the loader performs a real format → the system starts normally |

### Why writing zeros is wrong

| | 1 GB of zeros | hardware factory reset |
| --- | --- | --- |
| Effect on the filesystem | destroys it (superblock and other metadata zeroed) | reformats it (produces a valid empty filesystem) |
| What Android sees | cannot mount | mounts normally |
| Android's response | **neither mounts nor reformats → deadlock** | mounts → starts normally |

The assumption at the time was "corrupt the filesystem and Android will reformat it". That
assumption is wrong.

### Hardware factory reset

```
1. unplug the TV, wait ~30 seconds
2. hold POWER + VOLUME DOWN on the TV body (not the remote)
3. keeping both held, plug the power back in
4. keep holding until the logo appears, then release
5. wait 3–10 minutes (the screen shows "erasing")
```

The important part: this is handled by the standby MCU, which **runs before Android does**,
so it can be triggered even when Android will not start at all.

Measured: the screen shows `erasing`, then a reboot, then the setup wizard, with the data
correctly formatted.

