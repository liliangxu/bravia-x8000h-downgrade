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

## Fixing the standby hang

This change selects the software L3 path in the two original Widevine service
definitions. The [research notes](research.md#standby-hangs-after-the-downgrade)
explain the blocked L1 call and the audio/power dependency.

Start with the raw `vendor.img` extracted from the firmware installed on the TV.
The TV is already running the downgraded system with the bootloader unlocked and
the replacement, verification-disabled vbmeta. The example below uses slot A.

On the computer, have `debugfs` and `e2fsck` from e2fsprogs, `img2simg` and
`simg2img` from Android libsparse, and `avbtool` with a compatible Android `fec`
executable in `PATH`. `AVBTOOL` is the path set in step 0. All image preparation
runs on the computer.

### Prepare the image and service files

Keep the extracted image as `vendor.original.img`. All subsequent writes go to
the working copy, `vendor.img`, in a local `vendor-work/` directory:

```bash
# Host files: vendor-work/vendor.original.img and vendor-work/vendor-avb.txt
mkdir vendor-work
cp /path/to/extracted/vendor.img vendor-work/vendor.original.img
cd vendor-work
shasum -a 256 vendor.original.img
python3 "$AVBTOOL" info_image --image vendor.original.img > vendor-avb.txt
```

Read the partition size, rollback index and salt from this vendor image. Its
rollback index is the one to preserve when rebuilding its footer; the replacement
top-level vbmeta has its own index from step 0.

```bash
# Host input: vendor-work/vendor-avb.txt
vendor_size=$(awk '/^Image size:/ {print $3}' vendor-avb.txt)
vendor_index=$(awk '/^Rollback Index:/ {print $3}' vendor-avb.txt)
vendor_salt=$(awk '/^[[:space:]]*Salt:/ {print $2}' vendor-avb.txt)
```

Extract the two init files. The paths inside `vendor.img` start at `/etc`,
because that filesystem is mounted at `/vendor` on the TV.

```bash
# Host output: vendor-work/widevine-1.1.rc and vendor-work/drm-1.0.rc
debugfs -R 'dump /etc/init/android.hardware.drm@1.1-service.widevine.rc widevine-1.1.rc' vendor.original.img
debugfs -R 'dump /etc/init/android.hardware.drm@1.0-service.rc drm-1.0.rc' vendor.original.img
```

In `widevine-1.1.rc`, add the setting to the Widevine service. Leave the earlier
data-migration service as it is:

```diff
--- /vendor/etc/init/android.hardware.drm@1.1-service.widevine.rc
+++ /vendor/etc/init/android.hardware.drm@1.1-service.widevine.rc
 service vendor.drm-widevine-hal-1-1 /vendor/bin/hw/android.hardware.drm@1.1-service.widevine
+    setenv FORCE_LEVEL3_OEMCRYPTO yes
     class hal
```

Add the same setting in `drm-1.0.rc`:

```diff
--- /vendor/etc/init/android.hardware.drm@1.0-service.rc
+++ /vendor/etc/init/android.hardware.drm@1.0-service.rc
 service vendor.drm-hal-1-0 /vendor/bin/hw/android.hardware.drm@1.0-service
+    setenv FORCE_LEVEL3_OEMCRYPTO yes
     class hal
```

### Put the files back and rebuild the image

Both original files occupy one 4096-byte block, and both edited files still fit
in that allocation. Find the blocks in your own image and check the edited sizes:

```bash
# Image paths: /etc/init/android.hardware.drm@1.1-service.widevine.rc
#              /etc/init/android.hardware.drm@1.0-service.rc
debugfs -R stats vendor.original.img
rc11_block=$(debugfs -R 'blocks /etc/init/android.hardware.drm@1.1-service.widevine.rc' vendor.original.img | xargs)
rc10_block=$(debugfs -R 'blocks /etc/init/android.hardware.drm@1.0-service.rc' vendor.original.img | xargs)
printf 'Widevine block: %s\nLegacy DRM block: %s\n' "$rc11_block" "$rc10_block"
wc -c widevine-1.1.rc drm-1.0.rc
```

Check that the block size is 4096, each block result is a single integer, and
each edited file is under 4096 bytes. Write into those existing blocks and
update the inode sizes. This retains the original inodes, permissions and
SELinux labels.

```bash
# Host working image: vendor-work/vendor.img
cp vendor.original.img vendor.img
python3 "$AVBTOOL" erase_footer --image vendor.img
dd if=widevine-1.1.rc of=vendor.img bs=4096 seek="$rc11_block" conv=notrunc
dd if=drm-1.0.rc of=vendor.img bs=4096 seek="$rc10_block" conv=notrunc
debugfs -w -R "sif /etc/init/android.hardware.drm@1.1-service.widevine.rc size $(wc -c < widevine-1.1.rc)" vendor.img
debugfs -w -R "sif /etc/init/android.hardware.drm@1.0-service.rc size $(wc -c < drm-1.0.rc)" vendor.img
e2fsck -fn vendor.img
```

Re-export the files and compare them with the edited copies. In each `stat`
result, check that the original mode, UID/GID and `security.selinux` label have
been retained.

```bash
# Host check files: vendor-work/widevine-1.1.check.rc and vendor-work/drm-1.0.check.rc
debugfs -R 'dump /etc/init/android.hardware.drm@1.1-service.widevine.rc widevine-1.1.check.rc' vendor.img
debugfs -R 'dump /etc/init/android.hardware.drm@1.0-service.rc drm-1.0.check.rc' vendor.img
cmp widevine-1.1.rc widevine-1.1.check.rc
cmp drm-1.0.rc drm-1.0.check.rc
debugfs -R 'stat /etc/init/android.hardware.drm@1.1-service.widevine.rc' vendor.img
debugfs -R 'stat /etc/init/android.hardware.drm@1.0-service.rc' vendor.img
```

Regenerate the hashtree, FEC and footer with the original vendor parameters:

```bash
# Host working image: vendor-work/vendor.img
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

The rebuilt footer uses `Algorithm: NONE`; the existing top-level vbmeta keeps
verification disabled for this modified image. Keep that setup unlocked.

### Flash vendor and check the next boot

This time the target is the slot already running the older firmware. Check that
both Android and fastboot report A before using `vendor_a` below.

```bash
# Host input: vendor-work/vendor-l3.sparse.img; TV target: vendor_a
adb shell getprop ro.boot.slot_suffix
adb reboot bootloader
fastboot getvar current-slot
fastboot -S 120M flash vendor_a vendor-l3.sparse.img
fastboot reboot
```

Only `vendor_a` is written. The existing slot selection, vbmeta and user data
stay in place. The 120 MiB transfer size fits the tested device's 128 MiB limit.

After reconnecting network ADB, check startup and both services:

```bash
# TV state: init services and /proc/sys/kernel/random/boot_id
adb connect <device-ip>:5555
adb shell getprop sys.boot_completed
adb shell getprop init.svc.vendor.drm-widevine-hal-1-1
adb shell getprop init.svc.vendor.drm-hal-1-0
adb shell cat /proc/sys/kernel/random/boot_id
adb shell getprop ro.boot.verifiedbootstate
adb shell dumpsys dropbox
```

The expected values are `1`, `running`, `running`, a boot ID, and `orange`.
Use an app that reports Widevine's `securityLevel` to check `L3`. Play video
through the usual audio output, try standby/wake repeatedly, and compare the
boot ID and watchdog entry timestamps. Then reboot once and repeat the check
to confirm that init applies the configuration on a fresh boot.

My persistent test completed ten cycles on the first boot and three on the
second; the [playback results](research.md#playback-in-l3) include the 4K check.
To restore the original service configuration, flash `vendor.original.img`
back to the same vendor partition.

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

