# Procedure

[简体中文](procedure.zh-CN.md) · [Research notes](research.md) · [README](../README.md)

These steps follow the run that worked. Other firmware combinations have not been tested.

The parts that matter are step 0 (building the replacement vbmeta) and step 8 (the hardware
factory reset). The flashing in between is ordinary fastboot work.

---

## What you need

- A device that boots Android normally, with network ADB authorised
- `adb`, `fastboot`, `openssl`, Python 3 and `avbtool` on the computer
- A complete firmware package older than what the device is running (see
  [Where the firmware comes from](#where-the-firmware-comes-from))
- A **data** USB cable, plugged into the device's **USB 2.0** port, with the computer as
  host (see [research notes](research.md#port-and-cable))
- User data backed up: the process erases it twice

All commands below run on the computer. Connect one device only.

---

## Where the firmware comes from

Firmware packages come from the device's OTA distribution server, not from the support
pages. Support pages list the current version only.

### The full OTA package

```
https://tv-update.sony.com.cn/OND/<year>/as/ch/<directory-id>/sony_atvotafull_2018_<version>_cna_auth.zip
```

What the segments mean:

| Segment | Meaning |
| --- | --- |
| `OND` | OTA distribution path |
| `<year>` | Year the directory was published; **not the release year of the package** |
| `as/ch` | Region: Asia / China |
| `<directory-id>` | e.g. `PS215299`; see below |
| `sony_atvotafull_2018_<version>_cna_auth.zip` | The package name |

The three parts of the package name:

| Part | Meaning |
| --- | --- |
| `sony_atvotafull_2018` | Fixed prefix |
| `<version>` | Ten decimal digits: the first ten digits of that version's rollback index, e.g. `16050861000636` → `1605086100` |
| `cna` | Region suffix: `cna` China, `naa` North America, `paa`, `eua` Europe |

### The directory id

This segment is not part of the package name; it only selects a directory. What is known
about it:

- **It has no relationship to the version number**, and there is no published definition
- **One version usually appears under several directories**, and one directory holds
  several versions
- **Nearby ids serve the same batch of packages** — packages from one period, in different
  regions, carry adjacent ids
- **The directory year and the `2018` in the package name can disagree**

So in practice:

1. The package name can be assembled directly once the version is known
2. Try the region suffixes for your target
3. Get directory ids by reading them from any older package URL that still opens
4. Try the adjacent ids too

There is also a flat path without the directory, useful for checking the package name is
right before hunting for an id:

```
https://tv-update.sony.com.cn/URL_archive/zip/sony_atvotafull_2018_<version>_cna_auth.zip
```

### Bootloader source (not firmware)

```
https://oss.sony.net/Products/Linux/TV/KD-65A9F_Asia_Ver66230.html
```

The U-Boot source package there is 49,312,462 bytes, MD5 `d1ecfa04477150694b3dac47390563e9`. The
source paths cited in these notes are relative to it. **It is a different thing from the
firmware package**: the source is what makes the logic checkable, the firmware is what gets
written to the device.

### Availability

Historical versions are pruned from the CDN. If a particular version can no longer be
obtained, use any version older than your current one whose complete package you can get.
The method is not tied to one older version: step 0 works the same way whichever you pick,
with the index taken from what the device is currently running. It has only been verified on
the combination above, so on another version the partition layout, update components and
bootloader behaviour are yours to confirm.

---

## 0. Build the replacement vbmeta

**This is the step most likely to go wrong, and the one with the worst consequences.**

Extract `vbmeta.img` from the firmware **the device is currently running** and read its
rollback index:

```bash
export AVBTOOL=/absolute/path/to/avbtool.py

bash tools/inspect-vbmeta.sh vbmeta_current.img
# note the Rollback Index in the output
```

**The current version, not the older one you are about to install.** The check rejects an
image index below the stored value, so taking the older package's value fails. Using the
current image's value satisfies the check without raising the stored value, assuming the
stored value matches the current image. The stored value itself was not read directly; see
the [research notes](research.md#why-it-would-not-boot).

**Do not guess this value either.** Too large and the RPMB value is raised permanently; too
small and the boot is rejected.

Then build the replacement:

```bash
bash tools/make-vbmeta.sh <the index you read> vbmeta_patched.img
bash tools/inspect-vbmeta.sh vbmeta_patched.img
```

The result should show:

| Field | Expected |
| --- | --- |
| Algorithm | `SHA256_RSA2048` |
| Flags | `2` |
| Descriptors | none |
| Size | 8192 bytes |
| Rollback Index | equal to the value you read from the current firmware |

The tested device ran 6.6230; its image carries `16062301000725`, given only to show the
format. **Do not copy that number.**

A fresh signing key changes the image hash, so compare the fields above rather than the
hash.

---

## 1. Get the older firmware into a slot

The device has two slots and runs one at a time. Check which:

```bash
adb shell getprop ro.boot.slot_suffix
```

It returns `_a` or `_b`. **The older firmware goes into the other one** — write A if it
says `_b`, B if it says `_a`.

Writing into the running slot destroys the system that is currently working. That is why the
inactive slot is the one used here.

Two ways to do this; neither is expanded here:

- **Write the partitions with `fastboot flash`.** Once unlocked you can write `boot_a`,
  `system_a`, `vendor_a`, `dtbo_a`, `linux_rootfs_a`, `3rd_a`, `recipe_a` and so on, using
  the suffix of the inactive slot.
  **Do not touch `uboot` (permanently protected), `upgrade` (where loader updates land), or
  `eeprom_A`.**
- **Submit it through the device's own update service.** How each route works is in the
  [research notes](research.md#getting-the-older-firmware-into-a-slot).

**Both only put the image in the slot. Neither makes the older firmware start.** That is
what step 3 onwards is for.

---

## 2. Enter fastboot

```bash
adb connect <device-ip>:5555
adb shell reboot bootloader
fastboot devices
```

Expect a line ending in `fastboot`. No output means the USB layer is wrong; work through
[research notes](research.md#port-and-cable) first. The screen will be black, which is
normal.

---

## 3. Unlock

```bash
fastboot flashing unlock
```

Unlocking submits a request to clear user data, but the command returning success does not
mean the format has happened — step 8 still does that. Without unlocking, the later `flash`
fails with `device locked, forbid to write flash.`

---

## 4. Write the replacement vbmeta

```bash
fastboot flash vbmeta_a vbmeta_patched.img
```

The `a` is **the slot you wrote in step 1**, not the one currently running; for slot B use
`vbmeta_b`. Change step 6 to match. Expect `OKAY` and a byte count.

---

## 5. Clear the fastboot marker

```bash
fastboot erase misc
```

`erase misc` also clears the A/B metadata, so it **has to come before the slot is set**.
Without it the next ordinary reboot lands back in fastboot.

---

## 6. Select the slot

```bash
fastboot set_active a
```

Point the active slot at **the one you wrote in step 1**, using the same suffix as the
`vbmeta` write in step 4.

---

## 7. Reboot

```bash
fastboot reboot
```

**All six fastboot commands returned `OKAY` in the tested run, and the whole sequence took
under a second.**

The device starts the older firmware. First boot takes a while.

---

## 8. Hardware factory reset

**Do not skip this, and do not substitute a software wipe.**

Do not reach for `fastboot erase userdata` instead. It returns in about 0.05 s, booting
afterwards behaves as if it had not been run, and it does not fix the boot problem.

```
1. unplug the TV, wait ~30 seconds
2. hold POWER + VOLUME DOWN on the TV body (not the remote)
3. keeping both held, plug the power back in
4. keep holding until the logo appears, then release
5. wait 3–10 minutes (the screen shows "erasing")
```

Why it has to be done this way is in the [research notes](research.md#clearing-userdata).

---

## 9. Verify

```bash
adb connect <device-ip>:5555
adb shell getprop ro.build.version.incremental    # should match the package you installed
adb shell getprop ro.boot.slot_suffix             # should match the slot you selected
adb shell getprop ro.boot.verifiedbootstate       # expect orange
adb shell getprop sys.boot_completed              # expect 1
```

The first two are judged against what you actually installed and selected.
`verifiedbootstate` reading `orange` means the bootloader is in the unlocked state, which
matches the state after this procedure; on its own it does not show that the replaced image
is in use.

`tools/check-state.sh` prints these along with the system version, model and vbmeta state in
one go. It only reads; it issues no package, settings, reboot or partition-write commands.

---

## Going back to the original firmware

```bash
adb shell reboot bootloader
fastboot erase misc
fastboot set_active <the other slot>
fastboot reboot
```

The order matches steps 5 and 6: clear `misc` first, then select the slot. Then factory reset
from the key combination again.

**This section was not tested.** It follows from the rules of the forward procedure rather
than from a run.

---

## Things to avoid

| | |
| --- | --- |
| `fastboot flashing lock` | modified metadata should not be used together with relocking |
| `fastboot flash uboot ...` | a bad bootloader write may leave the device unable to start; recovery is unverified |
| `fastboot erase userdata` as the wipe | returns in about 0.05 s but does not fix the boot |
| writing zeros over `userdata` | Android neither mounts nor formats it |
| writing the older firmware into the active slot | destroys the system that currently works |
| skipping step 8 | the older system cannot read the newer userdata |
| letting the device back online to update | a later OTA may overwrite the replacement metadata and affect booting after the downgrade |

