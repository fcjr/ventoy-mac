/* MBR/GPT layout computation, ported from Ventoy2Disk Utility.c. */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "ventoy2disk.h"

void vt_gen_guid(void *guid)
{
    arc4random_buf(guid, 16);
}

static int fill_mbr_location(uint64_t disk_size_bytes, uint32_t start_sector_id,
                             uint32_t sector_count, PART_TABLE *table)
{
    uint8_t head;
    uint8_t sector;
    uint8_t n_sector = 63;
    uint8_t n_head = 8;
    uint32_t cylinder;
    uint32_t end_sector_id;

    while (n_head != 0 && (disk_size_bytes / 512 / n_sector / n_head) > 1024)
    {
        n_head = (uint8_t)(n_head * 2);
    }

    if (n_head == 0)
    {
        n_head = 255;
    }

    cylinder = start_sector_id / n_sector / n_head;
    head = start_sector_id / n_sector % n_head;
    sector = start_sector_id % n_sector + 1;

    table->StartHead = head;
    table->StartSector = sector;
    table->StartCylinder = cylinder;

    end_sector_id = start_sector_id + sector_count - 1;
    cylinder = end_sector_id / n_sector / n_head;
    head = end_sector_id / n_sector % n_head;
    sector = end_sector_id % n_sector + 1;

    table->EndHead = head;
    table->EndSector = sector;
    table->EndCylinder = cylinder;

    table->StartSectorId = start_sector_id;
    table->SectorCount = sector_count;

    return 0;
}

int vt_fill_mbr(uint64_t disk_size_bytes, MBR_HEAD *mbr, int reserve_mb,
                const uint8_t *boot_img)
{
    GUID guid;
    uint32_t disk_signature;
    uint32_t disk_sector_count;
    uint32_t part_sector_count;
    uint32_t part_start_sector;
    uint32_t reserved_sector;

    memset(mbr, 0, sizeof(*mbr));
    memcpy(mbr->BootCode, boot_img, 446);

    vt_gen_guid(&guid);
    memcpy(&disk_signature, &guid, sizeof(uint32_t));

    *((uint32_t *)(mbr->BootCode + 0x1B8)) = disk_signature;
    memcpy(mbr->BootCode + 0x180, &guid, 16);

    if (disk_size_bytes / 512 > 0xFFFFFFFF)
    {
        disk_sector_count = 0xFFFFFFFF;
    }
    else
    {
        disk_sector_count = (uint32_t)(disk_size_bytes / 512);
    }

    reserved_sector = (reserve_mb > 0) ? (uint32_t)reserve_mb * 2048 : 0;

    /* align part2 start with 4KB */
    {
        uint64_t sectors = disk_size_bytes / 512;
        if (sectors % 8)
        {
            reserved_sector += (uint32_t)(sectors % 8);
        }
    }

    /* Part1 */
    part_start_sector = VENTOY_PART1_START_SECTOR;
    part_sector_count = disk_sector_count - reserved_sector - VENTOY_EFI_PART_SECTORS - part_start_sector;
    fill_mbr_location(disk_size_bytes, part_start_sector, part_sector_count, mbr->PartTbl);

    mbr->PartTbl[0].Active = 0x80;
    mbr->PartTbl[0].FsFlag = 0x07; /* exFAT/NTFS */

    /* Part2 */
    part_start_sector += part_sector_count;
    part_sector_count = VENTOY_EFI_PART_SECTORS;
    fill_mbr_location(disk_size_bytes, part_start_sector, part_sector_count, mbr->PartTbl + 1);

    mbr->PartTbl[1].Active = 0x00;
    mbr->PartTbl[1].FsFlag = 0xEF; /* EFI System Partition */

    mbr->Byte55 = 0x55;
    mbr->ByteAA = 0xAA;

    return 0;
}

static int fill_protect_mbr(uint64_t disk_size_bytes, MBR_HEAD *mbr,
                            const uint8_t *boot_img)
{
    GUID guid;
    uint32_t disk_signature;
    uint64_t disk_sector_count;

    memset(mbr, 0, sizeof(*mbr));
    memcpy(mbr->BootCode, boot_img, 446);

    vt_gen_guid(&guid);
    memcpy(&disk_signature, &guid, sizeof(uint32_t));

    *((uint32_t *)(mbr->BootCode + 0x1B8)) = disk_signature;
    memcpy(mbr->BootCode + 0x180, &guid, 16);

    disk_sector_count = disk_size_bytes / 512 - 1;
    if (disk_sector_count > 0xFFFFFFFF)
    {
        disk_sector_count = 0xFFFFFFFF;
    }

    mbr->PartTbl[0].Active = 0x00;
    mbr->PartTbl[0].FsFlag = 0xEE;

    mbr->PartTbl[0].StartHead = 0;
    mbr->PartTbl[0].StartSector = 1;
    mbr->PartTbl[0].StartCylinder = 0;
    mbr->PartTbl[0].EndHead = 254;
    mbr->PartTbl[0].EndSector = 63;
    mbr->PartTbl[0].EndCylinder = 1023;

    mbr->PartTbl[0].StartSectorId = 1;
    mbr->PartTbl[0].SectorCount = (uint32_t)disk_sector_count;

    mbr->Byte55 = 0x55;
    mbr->ByteAA = 0xAA;

    /* grub stage1 blocklist: core.img starts at sector 34 on GPT disks */
    mbr->BootCode[92] = 0x22;

    return 0;
}

int vt_fill_gpt(uint64_t disk_size_bytes, VTOY_GPT_INFO *gpt, int reserve_mb,
                const uint8_t *boot_img)
{
    uint64_t reserved_sector = 33;
    uint64_t part1_sector_count;
    uint64_t disk_sector_count = disk_size_bytes / 512;
    VTOY_GPT_HDR *head = &gpt->Head;
    VTOY_GPT_PART_TBL *table = gpt->PartTbl;
    static const GUID kWindowsDataPartType =
        { 0xebd0a0a2, 0xb9e5, 0x4433, { 0x87, 0xc0, 0x68, 0xb6, 0xb7, 0x26, 0x99, 0xc7 } };
    static const uint16_t kNameVentoy[6] = { 'V', 'e', 'n', 't', 'o', 'y' };
    static const uint16_t kNameVtoyEfi[7] = { 'V', 'T', 'O', 'Y', 'E', 'F', 'I' };

    memset(gpt, 0, sizeof(*gpt));
    fill_protect_mbr(disk_size_bytes, &gpt->MBR, boot_img);

    if (reserve_mb > 0)
    {
        reserved_sector += (uint64_t)reserve_mb * 2048;
    }

    part1_sector_count = disk_sector_count - reserved_sector - VENTOY_EFI_PART_SECTORS - 2048;

    /* align part2 start with 4KB */
    if (part1_sector_count % 8)
    {
        part1_sector_count -= (part1_sector_count % 8);
    }

    memcpy(head->Signature, "EFI PART", 8);
    head->Version[2] = 0x01;
    head->Length = 92;
    head->Crc = 0;
    head->EfiStartLBA = 1;
    head->EfiBackupLBA = disk_sector_count - 1;
    head->PartAreaStartLBA = 34;
    head->PartAreaEndLBA = disk_sector_count - 34;
    vt_gen_guid(&head->DiskGuid);
    head->PartTblStartLBA = 2;
    head->PartTblTotNum = 128;
    head->PartTblEntryLen = 128;

    memcpy(&table[0].PartType, &kWindowsDataPartType, sizeof(GUID));
    vt_gen_guid(&table[0].PartGuid);
    table[0].StartLBA = 2048;
    table[0].LastLBA = 2048 + part1_sector_count - 1;
    table[0].Attr = 0;
    memcpy(table[0].Name, kNameVentoy, sizeof(kNameVentoy));

    /* Windows-data type instead of ESP type, matching upstream ("to fix
       windows issue"); the ESP attribute bit marks it for firmware. */
    memcpy(&table[1].PartType, &kWindowsDataPartType, sizeof(GUID));
    vt_gen_guid(&table[1].PartGuid);
    table[1].StartLBA = table[0].LastLBA + 1;
    table[1].LastLBA = table[1].StartLBA + VENTOY_EFI_PART_SECTORS - 1;
    table[1].Attr = VENTOY_EFI_PART_ATTR;
    memcpy(table[1].Name, kNameVtoyEfi, sizeof(kNameVtoyEfi));

    head->PartTblCrc = vt_crc32(table, sizeof(gpt->PartTbl));
    head->Crc = vt_crc32(head, head->Length);

    return 0;
}

int vt_fill_backup_gpt_head(const VTOY_GPT_INFO *gpt, VTOY_GPT_HDR *head)
{
    uint64_t lba;
    uint64_t backup_lba;

    memcpy(head, &gpt->Head, sizeof(VTOY_GPT_HDR));

    lba = head->EfiStartLBA;
    backup_lba = head->EfiBackupLBA;

    head->EfiStartLBA = backup_lba;
    head->EfiBackupLBA = lba;
    head->PartTblStartLBA = backup_lba + 1 - 33;

    head->Crc = 0;
    head->Crc = vt_crc32(head, head->Length);

    return 0;
}
