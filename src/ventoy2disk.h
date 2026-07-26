/******************************************************************************
 * ventoy2disk.h -- Ventoy installer for macOS
 *
 * Partition/GPT structures and layout logic derived from Ventoy
 * (https://www.ventoy.net) Ventoy2Disk, Copyright (c) 2020 longpanda
 * <admin@ventoy.net>, licensed under GPLv3+.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 3 of the
 * License, or (at your option) any later version.
 *****************************************************************************/

#ifndef __VENTOY2DISK_H__
#define __VENTOY2DISK_H__

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define VENTOY_PART1_START_SECTOR   2048
#define VENTOY_EFI_PART_SIZE        (32 * 1024 * 1024)
#define VENTOY_EFI_PART_SECTORS     (VENTOY_EFI_PART_SIZE / 512)
#define VENTOY_EFI_PART_ATTR        0x8000000000000000ULL

#define SIZE_1MB                    (1024 * 1024)

uint32_t vt_crc32(const void *buffer, uint32_t length);

#pragma pack(1)

typedef struct GUID
{
    uint32_t data1;
    uint16_t data2;
    uint16_t data3;
    uint8_t  data4[8];
} GUID;

typedef struct PART_TABLE
{
    uint8_t  Active;

    uint8_t  StartHead;
    uint16_t StartSector : 6;
    uint16_t StartCylinder : 10;

    uint8_t  FsFlag;

    uint8_t  EndHead;
    uint16_t EndSector : 6;
    uint16_t EndCylinder : 10;

    uint32_t StartSectorId;
    uint32_t SectorCount;
} PART_TABLE;

typedef struct MBR_HEAD
{
    uint8_t BootCode[446];
    PART_TABLE PartTbl[4];
    uint8_t Byte55;
    uint8_t ByteAA;
} MBR_HEAD;

typedef struct VTOY_GPT_HDR
{
    char     Signature[8]; /* EFI PART */
    uint8_t  Version[4];
    uint32_t Length;
    uint32_t Crc;
    uint8_t  Reserved1[4];
    uint64_t EfiStartLBA;
    uint64_t EfiBackupLBA;
    uint64_t PartAreaStartLBA;
    uint64_t PartAreaEndLBA;
    GUID     DiskGuid;
    uint64_t PartTblStartLBA;
    uint32_t PartTblTotNum;
    uint32_t PartTblEntryLen;
    uint32_t PartTblCrc;
    uint8_t  Reserved2[420];
} VTOY_GPT_HDR;

typedef struct VTOY_GPT_PART_TBL
{
    GUID     PartType;
    GUID     PartGuid;
    uint64_t StartLBA;
    uint64_t LastLBA;
    uint64_t Attr;
    uint16_t Name[36];
} VTOY_GPT_PART_TBL;

typedef struct VTOY_GPT_INFO
{
    MBR_HEAD MBR;
    VTOY_GPT_HDR Head;
    VTOY_GPT_PART_TBL PartTbl[128];
} VTOY_GPT_INFO;

typedef struct VTOY_BK_GPT_INFO
{
    VTOY_GPT_PART_TBL PartTbl[128];
    VTOY_GPT_HDR Head;
} VTOY_BK_GPT_INFO;

#pragma pack()

_Static_assert(sizeof(MBR_HEAD) == 512, "MBR size");
_Static_assert(sizeof(VTOY_GPT_HDR) == 512, "GPT header size");
_Static_assert(sizeof(VTOY_GPT_PART_TBL) == 128, "GPT entry size");
_Static_assert(sizeof(VTOY_GPT_INFO) == 512 * 34, "GPT info size");
_Static_assert(sizeof(VTOY_BK_GPT_INFO) == 512 * 33, "Backup GPT size");

/* disk_macos.c */
typedef struct vt_disk
{
    char bsdname[32];          /* disk4 */
    char dev[64];              /* /dev/disk4 */
    char rdev[64];             /* /dev/rdisk4 */
    int fd;                    /* open fd on rdev */
    uint32_t sector_size;
    uint64_t sector_count;
    uint64_t size_bytes;
} vt_disk;

int vt_disk_open(const char *arg, vt_disk *disk, bool write);
void vt_disk_close(vt_disk *disk);
int vt_disk_unmount(const vt_disk *disk);
int vt_disk_is_system_disk(const vt_disk *disk);
int vt_pread(const vt_disk *disk, void *buf, uint64_t len, uint64_t offset);
int vt_pwrite(const vt_disk *disk, const void *buf, uint64_t len, uint64_t offset);
int vt_disk_sync(const vt_disk *disk);

/* ff_diskio.c (FatFs glue) */
void vt_ff_set_target(const vt_disk *disk, uint64_t total_sectors);
int vt_ff_write_error(void);

/* partition.c */
void vt_gen_guid(void *guid);
int vt_fill_mbr(uint64_t disk_size_bytes, MBR_HEAD *mbr, int reserve_mb,
                const uint8_t *boot_img);
int vt_fill_gpt(uint64_t disk_size_bytes, VTOY_GPT_INFO *gpt, int reserve_mb,
                const uint8_t *boot_img);
int vt_fill_backup_gpt_head(const VTOY_GPT_INFO *gpt, VTOY_GPT_HDR *head);

/* xzdec.c */
int vt_unxz(const uint8_t *in, size_t in_size, uint8_t *out, size_t out_cap,
            size_t *out_len);

/* payload.c */
typedef struct vt_pack
{
    char dir[1024];
    char version[64];
    uint8_t boot_img[512];
    uint8_t *core_img;         /* decompressed, zero-padded to core_cap */
    size_t core_len;
    uint8_t *disk_img;         /* decompressed ventoy.disk.img, 32MB */
} vt_pack;

int vt_pack_locate(const char *pack_dir, vt_pack *pack); /* pack_dir NULL => download/cache */
int vt_pack_load(vt_pack *pack);
void vt_pack_free(vt_pack *pack);

/* secureboot.c */
int vt_proc_secure_boot(uint8_t *disk_img, bool secure_boot_support);

/* fatpart.c: helpers that read the part2 FAT filesystem on the raw disk */
int vt_part2_get_version(const vt_disk *disk, uint64_t part2_start_sector,
                         char *ver, size_t ver_len);
int vt_part2_secure_boot_enabled(const vt_disk *disk, uint64_t part2_start_sector);

/* format.c */
int vt_format_part1_exfat(const vt_disk *disk, uint64_t part1_end_sector,
                          const char *label);

/* install.c */
typedef struct vt_opts
{
    int mode;                  /* 'i' install, 'u' update, 'l' list */
    bool force;
    bool gpt;
    bool secure_boot;
    bool secure_boot_set;      /* -s/-S given explicitly */
    bool yes;                  /* skip confirmation prompts */
    int reserve_mb;
    const char *label;
    const char *pack_dir;
    const char *disk_arg;
} vt_opts;

int vt_install(const vt_opts *opts);
int vt_update(const vt_opts *opts);
int vt_list(const vt_opts *opts);

#endif /* __VENTOY2DISK_H__ */
