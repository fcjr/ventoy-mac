# ventoy-mac

A native macOS CLI and GUI to install [Ventoy](https://www.ventoy.net) on a
USB drive — a port of the official `Ventoy2Disk` installer.

Ventoy makes a USB drive that boots ISO files directly: install it once, then
just copy ISOs onto the drive. The resulting drive boots PCs (BIOS and UEFI);
this tool simply lets you prepare such a drive from a Mac.

## Usage

```
ventoy2disk CMD [ OPTION ] /dev/diskN

  CMD:
   -i  install Ventoy (fails if already installed)
   -I  force install
   -u  update Ventoy on the drive (keeps files on the data partition)
   -l  show Ventoy info on the drive

  OPTION:
   -r SIZE_MB  preserve space at the end of the disk (install only)
   -s/-S       enable/disable secure boot support (default enabled)
   -g          GPT partition style (default MBR, install only)
   -L LABEL    exFAT volume label (default "Ventoy")
   -y          no confirmation prompts
   --pack DIR  use payloads from an extracted ventoy-x.y.z-linux package
```

Find your drive with `diskutil list external`, then:

```sh
sudo ventoy2disk -i /dev/disk4
```

Boot payloads (GRUB images, EFI partition image) are taken from the official
Ventoy release package: the latest `ventoy-x.y.z-linux.tar.gz` is downloaded
from GitHub on first use and cached under
`~/Library/Caches/com.leftshift.ventoy/`. Use `--pack` to point at an
already-extracted package instead (offline use).

## GUI

```sh
make app
open build/Ventoy2Disk.app
```

A SwiftUI app (macOS 14+) in the Disk Utility style: external disks in a
sidebar, a partition map and info pane per disk, install options in an
erase sheet, and progress with a details console. It embeds the CLI and
runs it through Authorization Services, so the password prompt is
attributed to Ventoy2Disk and no `sudo` is needed.

Only physical external disks are listed. To test against an attached disk
image (`hdiutil attach -nomount`), run
`defaults write com.leftshift.ventoy.app ShowVirtualDisks -bool YES`.

## Build

```sh
make        # CLI only
make app    # CLI + Ventoy2Disk.app
```

Produces a universal (arm64 + x86_64) `build/ventoy2disk`, codesigned as
`com.leftshift.ventoy` when the signing identity is available (the app is
signed as `com.leftshift.ventoy.app`).

## Design notes

The installer performs the same steps as the official Windows/Linux
installers:

1. Two partitions: partition 1 (exFAT, all space minus 32MB, starting at
   sector 2048) and partition 2 (`VTOYEFI`, exactly 65536 sectors at the end
   of the disk, 4KB-aligned).
2. Partition 1 is formatted exFAT via FatFs `f_mkfs` (32KB clusters ≤ 32GB,
   128KB above).
3. Partition 2 content is the release's `ventoy.disk.img` written verbatim
   (with the secure-boot EFI file swap applied in memory when `-S` is used).
4. GRUB stage1: `boot.img` boot code into the MBR/protective MBR,
   `core.img` at sector 1 (MBR) or 34 (GPT, with blocklist patch).
5. Partition tables are written directly (no `diskutil partitionDisk`), so
   the layout matches upstream byte-for-byte.

Vendored third-party code (in `vendor/`): FatFs R0.14 with Ventoy's
modifications, ultra-embedded fat_io_lib, and xz-embedded — all taken from
the Ventoy source tree.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE). The installer logic is a port of
Ventoy's `Ventoy2Disk`, Copyright (c) longpanda \<admin@ventoy.net\>,
licensed GPLv3+. macOS-specific code Copyright (c) 2026 Frank Chiarulli Jr.

Vendored components under `vendor/`, each with its upstream license text:

- `vendor/ff14` — FatFs R0.14 by ChaN (one-clause BSD-style FatFs license,
  see `vendor/ff14/LICENSE.txt`), including Ventoy's modifications.
- `vendor/fat_io_lib` — FAT File IO Library by ultra-embedded.com,
  GPL-2.0-or-later (see `vendor/fat_io_lib/License.txt`).
- `vendor/xz` — xz-embedded by Lasse Collin and Igor Pavlov, public domain.

All components are GPL-3.0-compatible, so the combined work is distributed
under GPL-3.0-or-later.
