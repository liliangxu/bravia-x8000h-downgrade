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
https://oss.sony.net/Products/Linux/TV/<model-page>.html
```

This is where the GPL source archives are published; the U-Boot one is about 49 MB. The
source paths cited in these notes are relative to it. **It is a different thing from the
firmware package**: the source is what makes the logic checkable, the firmware is what gets
written to the device.

### Availability

Historical versions are pruned from the CDN. If a particular version can no longer be
obtained, use any version older than your current one whose complete package you can get.
The method is not version-specific: whichever older version you pick, step 0 works the same
way, with the index taken from what the device is currently running.

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

**The current version, not the older one you are about to install.** RPMB holds the index of
the highest version that has been on the device, and the replacement has to be equal to it.
Taking the older package's value fails the check.

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

The index read on the tested device was `16062301000725`, given only to show the format.
**Do not copy that number.**

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

Writing into the running slot replaces the system with the older one while its metadata is
still the new version. On reboot the check fails and the older system will not start, and
both slots are then new, so there is nothing to fall back to.

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

**This erases user data.** Without it the later `flash` fails with
`device locked, forbid to write flash.`

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

Do not reach for `fastboot erase userdata` instead. On this platform that command issues a
TRIM and moves no data at all.

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
`verifiedbootstate` reading `orange` means verification is off and the replaced metadata is
in use.

`tools/check-state.sh` prints these along with the system version, model and vbmeta state in
one go. It only reads; it issues no package, settings, reboot or partition-write commands.

---

## Going back to the original firmware

```bash
adb shell reboot bootloader
fastboot set_active <the other slot>
fastboot erase misc
fastboot reboot
```

Then factory reset from the key combination again. The userdata mismatch happens in both
directions.

---

## Things that will break the device

| | |
| --- | --- |
| `fastboot flashing lock` | `erase misc` is then refused, and there is no way out of fastboot |
| `fastboot flash uboot ...` | breaks the bootloader signature; permanent brick |
| `fastboot erase userdata` as the wipe | issues a TRIM only; data survives |
| writing zeros over `userdata` | Android neither mounts nor formats it |
| writing the older firmware into the active slot | overwrites the running system, with no slot left to fall back to |
| skipping step 8 | the older system cannot read the newer userdata |
| letting the device back online to update | the OTA arrives immediately and undoes the work |

