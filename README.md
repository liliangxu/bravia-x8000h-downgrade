# bravia-x8000h-downgrade

[简体中文](README.zh-CN.md)

Research notes and small tools from downgrading my BRAVIA KD-49X8000H from
`PKG6.6230` (Android 10) to `PKG6.5086` (Android 9).

The older firmware went into the inactive slot, then USB fastboot replaced that
slot's `vbmeta`, and a factory reset completed the installation. No disassembly,
UART connection or eMMC programmer was needed.

## Tested configuration

| Item | Value |
| --- | --- |
| TV | KD-49X8000H, Chinese firmware |
| Platform | X8000H / GN6UR / MediaTek MT5893 |
| Starting firmware | PKG6.6230.0725CNA, Android 10, build `662301`, slot B |
| Target firmware | PKG6.5086, Android 9, build `650861`, installed into slot A |
| Result | Android 9 completed setup and booted again after an ordinary restart |

The procedure was tested on this one TV and firmware combination. The research
discusses the X8000H/GN6UR platform, but a shared chassis or source release does
not establish compatibility with other models or regions.

## Read the notes

- [Research notes](docs/research.md) — how the older firmware gets into a slot, why it
  would not boot, the replacement vbmeta, how fastboot is entered, and the userdata problem.
- [Procedure](docs/procedure.md) — what to prepare, where the firmware comes from, the
  commands, the USB connection, the factory reset, and the checks.

The procedure follows the successful run. The notes explain the decisions needed
to reproduce it; the full investigation and post-downgrade update management are
outside their scope.

## Tools

| File | Purpose |
| --- | --- |
| [inspect-vbmeta.sh](tools/inspect-vbmeta.sh) | Read AVB metadata from an image |
| [make-vbmeta.sh](tools/make-vbmeta.sh) | Generate replacement metadata with a supplied rollback index |
| [check-state.sh](tools/check-state.sh) | Read build, slot and boot properties over ADB |

Dependencies and usage are in the [procedure](docs/procedure.md).
Installation, unlocking and flashing remain separate commands to run and check.
These helpers were prepared for publication and tested locally; the entire
downgrade has not been repeated with this edition of the tools.

## Before you start

The procedure writes firmware, unlocks the bootloader, disables AVB verification
for the target slot, and clears user data. Back up your data first. An incorrect
image, partition or rollback index can leave the TV unable to boot; a working
recovery path is not guaranteed. DRM and other certified features were not
comprehensively tested. Do not relock the bootloader with modified metadata installed.

Firmware, signing keys, generated images and third-party executables are not
included. The [procedure](docs/procedure.md#what-you-need) lists the inputs you need;
[one section there](docs/procedure.md#where-the-firmware-comes-from) gives the download
path pattern, and notes that historical versions are pruned from the CDN.

## Scope and responsibility

- All work was done on hardware the author owns. On other hardware or in other regions,
  the risks and the compliance questions are the operator's to judge.
- Bricked devices, lost data and broken features are the operator's own risk. Unlocking a
  bootloader usually voids the warranty.
- This repository contains no firmware packages, signing keys or derived images.
- These are research notes, not instructions for working on someone else's device.

## License

Scripts in this repository are [MIT](LICENSE), the documentation is
[CC BY 4.0](LICENSE-docs). External source, firmware and tools keep their own licenses.

Thanks to the authors and maintainers of that source and of the tools used here.
