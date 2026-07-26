/* Install / update / list flows, following Ventoy2Disk and VentoyWorker.sh. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ventoy2disk.h"

#define CORE_SECTORS_MBR  2047   /* core.img at sectors 1..2047  */
#define CORE_SECTORS_GPT  2014   /* core.img at sectors 34..2047 */
#define RSV_START_SECTOR  2040   /* 8 sectors preserved across updates */
#define RSV_SECTORS       8

static int confirm(const char *prompt)
{
    char line[64];

    printf("%s (y/n) ", prompt);
    fflush(stdout);

    if (!fgets(line, sizeof(line), stdin))
    {
        return 0;
    }

    return (line[0] == 'y' || line[0] == 'Y');
}

static void print_disk_summary(const vt_disk *disk, const char *style)
{
    printf("\nDisk : %s\n", disk->dev);
    printf("Size : %llu GiB\n", (unsigned long long)(disk->size_bytes / 1024 / 1024 / 1024));
    printf("Style: %s\n\n", style);
}

/* read sector 0 + GPT area, detect layout, return part2 start sector (0 if
 * the disk does not contain a valid ventoy layout) */
static uint64_t find_ventoy_part2(const vt_disk *disk, int *is_gpt)
{
    MBR_HEAD mbr;
    VTOY_GPT_INFO *gpt;
    uint64_t part2_start = 0;

    if (vt_pread(disk, &mbr, 512, 0))
    {
        return 0;
    }

    if (mbr.PartTbl[0].FsFlag == 0xEE)
    {
        *is_gpt = 1;

        gpt = malloc(sizeof(VTOY_GPT_INFO));
        if (!gpt)
        {
            return 0;
        }
        if (vt_pread(disk, gpt, sizeof(VTOY_GPT_INFO), 0) == 0 &&
            memcmp(gpt->Head.Signature, "EFI PART", 8) == 0 &&
            gpt->PartTbl[0].StartLBA == VENTOY_PART1_START_SECTOR &&
            gpt->PartTbl[1].StartLBA > 0 &&
            gpt->PartTbl[1].LastLBA - gpt->PartTbl[1].StartLBA + 1 == VENTOY_EFI_PART_SECTORS)
        {
            part2_start = gpt->PartTbl[1].StartLBA;
        }
        free(gpt);
    }
    else
    {
        *is_gpt = 0;

        if (mbr.Byte55 == 0x55 && mbr.ByteAA == 0xAA &&
            mbr.PartTbl[0].StartSectorId == VENTOY_PART1_START_SECTOR &&
            mbr.PartTbl[1].SectorCount == VENTOY_EFI_PART_SECTORS)
        {
            part2_start = mbr.PartTbl[1].StartSectorId;
        }
    }

    return part2_start;
}

static int write_core_img(const vt_disk *disk, const vt_pack *pack, int gpt)
{
    int rc;
    uint8_t *buf;

    buf = calloc(1, CORE_SECTORS_MBR * 512);
    if (!buf)
    {
        return 1;
    }

    memcpy(buf, pack->core_img, pack->core_len);

    if (gpt)
    {
        buf[500] = 35; /* stage1 blocklist: first core sector on GPT disks */
        rc = vt_pwrite(disk, buf, CORE_SECTORS_GPT * 512, 34 * 512);
    }
    else
    {
        rc = vt_pwrite(disk, buf, CORE_SECTORS_MBR * 512, 1 * 512);
    }

    free(buf);
    return rc;
}

static int write_part2_img(const vt_disk *disk, vt_pack *pack,
                           uint64_t part2_start, bool secure_boot)
{
    if (vt_proc_secure_boot(pack->disk_img, secure_boot))
    {
        fprintf(stderr, "Failed to process secure boot settings\n");
        return 1;
    }

    return vt_pwrite(disk, pack->disk_img, VENTOY_EFI_PART_SIZE,
                     part2_start * 512);
}

static int common_open_checks(const vt_opts *opts, vt_disk *disk, bool write)
{
    if (vt_disk_open(opts->disk_arg, disk, write))
    {
        return 1;
    }

    if (disk->sector_size != 512)
    {
        fprintf(stderr, "Ventoy does not support this device: sector size is %u, only 512 is supported.\n",
                disk->sector_size);
        vt_disk_close(disk);
        return 1;
    }

    if (write && vt_disk_is_system_disk(disk))
    {
        fprintf(stderr, "%s is the system disk. Refusing to touch it.\n", disk->dev);
        vt_disk_close(disk);
        return 1;
    }

    return 0;
}

int vt_install(const vt_opts *opts)
{
    int rc = 1;
    int old_gpt = 0;
    vt_disk disk;
    vt_pack pack;
    MBR_HEAD mbr;
    VTOY_GPT_INFO *gpt = NULL;
    VTOY_GPT_HDR backup_head;
    uint64_t part1_sectors;
    uint64_t part2_start;
    char oldver[64] = { 0 };
    uint8_t zero_buf[512 * 33];

    if (vt_pack_locate(opts->pack_dir, &pack) || vt_pack_load(&pack))
    {
        return 1;
    }

    if (common_open_checks(opts, &disk, true))
    {
        vt_pack_free(&pack);
        return 1;
    }

    if (disk.sector_count <= 4 * 1024 * 1024 / 512 + VENTOY_EFI_PART_SECTORS + VENTOY_PART1_START_SECTOR + 33)
    {
        fprintf(stderr, "No enough space in disk %s\n", disk.dev);
        goto out;
    }

    if (disk.sector_count > 4294967296ULL && !opts->gpt)
    {
        fprintf(stderr, "%s is over 2TB, MBR will not work on it, use -g for GPT.\n", disk.dev);
        goto out;
    }

    if (opts->reserve_mb > 0)
    {
        uint64_t need = ((uint64_t)opts->reserve_mb + 32 + 2) * 2048;
        if (disk.sector_count <= need)
        {
            fprintf(stderr, "Can't reserve %d MiB from %s\n", opts->reserve_mb, disk.dev);
            goto out;
        }
    }

    /* refuse reinstall without -I */
    part2_start = find_ventoy_part2(&disk, &old_gpt);
    if (part2_start &&
        vt_part2_get_version(&disk, part2_start, oldver, sizeof(oldver)) == 0)
    {
        if (!opts->force)
        {
            fprintf(stderr, "%s already contains Ventoy %s\n", disk.dev, oldver);
            fprintf(stderr, "Use -u to do a safe upgrade, or -I to force a reinstall.\n");
            goto out;
        }
    }

    print_disk_summary(&disk, opts->gpt ? "GPT" : "MBR");
    printf("Ventoy version: %s\n", pack.version);
    printf("Secure boot support: %s\n", opts->secure_boot ? "YES" : "NO");
    if (opts->reserve_mb > 0)
    {
        printf("Reserved space: %d MiB\n", opts->reserve_mb);
    }

    if (!opts->yes)
    {
        printf("\nWARNING: All data on %s will be lost!\n", disk.dev);
        if (!confirm("Continue?"))
        {
            rc = 0;
            goto out;
        }
        printf("\nWARNING: All data on %s will be lost!\n", disk.dev);
        if (!confirm("Double-check. Continue?"))
        {
            rc = 0;
            goto out;
        }
    }

    if (vt_disk_unmount(&disk))
    {
        fprintf(stderr, "Failed to unmount %s. Close any programs using it and retry.\n", disk.dev);
        goto out;
    }

    /* compute layout */
    if (opts->gpt)
    {
        gpt = calloc(1, sizeof(VTOY_GPT_INFO));
        if (!gpt)
        {
            goto out;
        }
        vt_fill_gpt(disk.size_bytes, gpt, opts->reserve_mb, pack.boot_img);
        part1_sectors = gpt->PartTbl[0].LastLBA - gpt->PartTbl[0].StartLBA + 1;
        part2_start = gpt->PartTbl[1].StartLBA;
    }
    else
    {
        vt_fill_mbr(disk.size_bytes, &mbr, opts->reserve_mb, pack.boot_img);
        part1_sectors = mbr.PartTbl[0].SectorCount;
        part2_start = mbr.PartTbl[1].StartSectorId;
    }

    /* clear old metadata: first 1MB and the trailing backup-GPT area */
    printf("Clearing old partition data ...\n");
    memset(zero_buf, 0, sizeof(zero_buf));
    for (int i = 0; i < 2048; i += 33)
    {
        int n = (2048 - i) < 33 ? (2048 - i) : 33;
        if (vt_pwrite(&disk, zero_buf, (uint64_t)n * 512, (uint64_t)i * 512))
        {
            fprintf(stderr, "Write to %s failed, please check whether it's in use.\n", disk.dev);
            goto out;
        }
    }
    vt_pwrite(&disk, zero_buf, 33 * 512, (disk.sector_count - 33) * 512);

    printf("Formatting partition 1 (exFAT, label '%s') ...\n", opts->label);
    if (vt_format_part1_exfat(&disk, VENTOY_PART1_START_SECTOR + part1_sectors, opts->label))
    {
        goto out;
    }

    printf("Writing EFI partition image ...\n");
    if (write_part2_img(&disk, &pack, part2_start, opts->secure_boot))
    {
        goto out;
    }

    printf("Writing boot image ...\n");
    if (write_core_img(&disk, &pack, opts->gpt))
    {
        goto out;
    }

    printf("Writing partition table ...\n");
    if (opts->gpt)
    {
        vt_fill_backup_gpt_head(gpt, &backup_head);

        if (vt_pwrite(&disk, &backup_head, 512, (disk.sector_count - 1) * 512) ||
            vt_pwrite(&disk, gpt->PartTbl, sizeof(gpt->PartTbl), (disk.sector_count - 33) * 512) ||
            vt_pwrite(&disk, gpt, sizeof(VTOY_GPT_INFO), 0))
        {
            goto out;
        }
    }
    else
    {
        if (vt_pwrite(&disk, &mbr, 512, 0))
        {
            goto out;
        }
    }

    printf("Syncing ...\n");
    vt_disk_sync(&disk);
    vt_disk_close(&disk);

    printf("\nInstall Ventoy %s to %s successfully finished.\n", pack.version, disk.dev);
    printf("You can now copy ISO files to the '%s' volume once macOS remounts it.\n", opts->label);
    rc = 0;

out:
    free(gpt);
    vt_disk_close(&disk);
    vt_pack_free(&pack);
    return rc;
}

int vt_update(const vt_opts *opts)
{
    int rc = 1;
    int is_gpt = 0;
    vt_disk disk;
    vt_pack pack;
    uint64_t part2_start;
    bool secure_boot;
    char oldver[64] = { 0 };
    char prompt[256];
    uint8_t sector0[512];
    uint8_t uuid[16];
    uint8_t rsvdata[RSV_SECTORS * 512];
    VTOY_GPT_INFO *gpt = NULL;

    if (vt_pack_locate(opts->pack_dir, &pack) || vt_pack_load(&pack))
    {
        return 1;
    }

    if (common_open_checks(opts, &disk, true))
    {
        vt_pack_free(&pack);
        return 1;
    }

    part2_start = find_ventoy_part2(&disk, &is_gpt);
    if (part2_start == 0)
    {
        fprintf(stderr, "%s does not contain Ventoy or data corrupted.\n", disk.dev);
        fprintf(stderr, "Please use -i to install ventoy to %s\n", disk.dev);
        goto out;
    }

    if (vt_part2_get_version(&disk, part2_start, oldver, sizeof(oldver)))
    {
        snprintf(oldver, sizeof(oldver), "Unknown");
    }

    /* preserve secure-boot state unless overridden on the command line */
    if (opts->secure_boot_set)
    {
        secure_boot = opts->secure_boot;
    }
    else
    {
        secure_boot = vt_part2_secure_boot_enabled(&disk, part2_start) != 0;
    }

    print_disk_summary(&disk, is_gpt ? "GPT" : "MBR");
    printf("Upgrade is safe: files on the first partition are unchanged.\n\n");

    if (!opts->yes)
    {
        snprintf(prompt, sizeof(prompt), "Update Ventoy %s ===> %s   Continue?", oldver, pack.version);
        if (!confirm(prompt))
        {
            rc = 0;
            goto out;
        }
    }

    if (vt_disk_unmount(&disk))
    {
        fprintf(stderr, "Failed to unmount %s. Close any programs using it and retry.\n", disk.dev);
        goto out;
    }

    /* refresh boot code (first 440 bytes), preserving disk uuid + signature */
    if (vt_pread(&disk, sector0, 512, 0))
    {
        goto out;
    }
    memcpy(uuid, sector0 + 0x180, 16);
    memcpy(sector0, pack.boot_img, 440);
    memcpy(sector0 + 0x180, uuid, 16);

    if (!is_gpt)
    {
        MBR_HEAD *mbr = (MBR_HEAD *)sector0;
        if (mbr->PartTbl[0].Active == 0x00 && mbr->PartTbl[1].Active == 0x80)
        {
            mbr->PartTbl[0].Active = 0x80;
            mbr->PartTbl[1].Active = 0x00;
        }
    }
    else
    {
        sector0[92] = 0x22;
    }

    if (vt_pwrite(&disk, sector0, 512, 0))
    {
        goto out;
    }

    /* rewrite core.img, preserving the reserved data sectors */
    if (vt_pread(&disk, rsvdata, sizeof(rsvdata), RSV_START_SECTOR * 512))
    {
        goto out;
    }

    printf("Writing boot image ...\n");
    if (write_core_img(&disk, &pack, is_gpt))
    {
        goto out;
    }

    if (vt_pwrite(&disk, rsvdata, sizeof(rsvdata), RSV_START_SECTOR * 512))
    {
        goto out;
    }

    printf("Writing EFI partition image ...\n");
    if (write_part2_img(&disk, &pack, part2_start, secure_boot))
    {
        goto out;
    }

    /* make sure the ESP attribute survives (vtoycli gpt -f) */
    if (is_gpt)
    {
        gpt = malloc(sizeof(VTOY_GPT_INFO));
        if (gpt && vt_pread(&disk, gpt, sizeof(VTOY_GPT_INFO), 0) == 0)
        {
            uint16_t *name = gpt->PartTbl[1].Name;
            if (name[0] == 'V' && name[1] == 'T' && name[2] == 'O' && name[3] == 'Y' &&
                gpt->PartTbl[1].Attr != VENTOY_EFI_PART_ATTR)
            {
                VTOY_GPT_HDR backup_head;

                gpt->PartTbl[1].Attr = VENTOY_EFI_PART_ATTR;
                gpt->Head.PartTblCrc = vt_crc32(gpt->PartTbl, sizeof(gpt->PartTbl));
                gpt->Head.Crc = 0;
                gpt->Head.Crc = vt_crc32(&gpt->Head, gpt->Head.Length);

                vt_fill_backup_gpt_head(gpt, &backup_head);

                vt_pwrite(&disk, (uint8_t *)gpt + 512, sizeof(VTOY_GPT_INFO) - 512, 512);
                vt_pwrite(&disk, gpt->PartTbl, sizeof(gpt->PartTbl), (disk.sector_count - 33) * 512);
                vt_pwrite(&disk, &backup_head, 512, (disk.sector_count - 1) * 512);
            }
        }
    }

    printf("Syncing ...\n");
    vt_disk_sync(&disk);
    vt_disk_close(&disk);

    printf("\nUpdate Ventoy %s ===> %s on %s successfully finished.\n", oldver, pack.version, disk.dev);
    rc = 0;

out:
    free(gpt);
    vt_disk_close(&disk);
    vt_pack_free(&pack);
    return rc;
}

int vt_list(const vt_opts *opts)
{
    int is_gpt = 0;
    vt_disk disk;
    uint64_t part2_start;
    char ver[64] = { 0 };

    if (common_open_checks(opts, &disk, false))
    {
        return 1;
    }

    part2_start = find_ventoy_part2(&disk, &is_gpt);
    if (part2_start == 0 ||
        vt_part2_get_version(&disk, part2_start, ver, sizeof(ver)))
    {
        printf("Ventoy Version: NA\n");
        vt_disk_close(&disk);
        return 1;
    }

    printf("Ventoy Version in Disk: %s\n", ver);
    printf("Disk Partition Style  : %s\n", is_gpt ? "GPT" : "MBR");
    printf("Secure Boot Support   : %s\n",
           vt_part2_secure_boot_enabled(&disk, part2_start) ? "YES" : "NO");

    vt_disk_close(&disk);
    return 0;
}
