/* FatFs low-level diskio glue.
 *
 * Same trick as upstream Ventoy2Disk: FatFs sees a "drive" spanning
 * sector 0 .. end-of-partition-1, so f_mkfs (FDISK mode) places the exFAT
 * volume at sector 2048 = Ventoy partition 1.  The MBR that f_mkfs writes
 * is cached in memory and never reaches the disk -- the real partition
 * table is written separately.
 */

#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "diskio.h"
#include "ventoy2disk.h"

static const vt_disk *g_disk = NULL;
static uint64_t g_total_sectors = 0;
static uint8_t g_mbr_sector[512];
static int g_write_error = 0;

void vt_ff_set_target(const vt_disk *disk, uint64_t total_sectors)
{
    g_disk = disk;
    g_total_sectors = total_sectors;
    g_write_error = 0;
    memset(g_mbr_sector, 0, sizeof(g_mbr_sector));
}

int vt_ff_write_error(void)
{
    return g_write_error;
}

DSTATUS disk_status(BYTE pdrv)
{
    (void)pdrv;
    return 0;
}

DSTATUS disk_initialize(BYTE pdrv)
{
    (void)pdrv;
    return 0;
}

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count)
{
    (void)pdrv;

    if (vt_pread(g_disk, buff, (uint64_t)count * 512, (uint64_t)sector * 512))
    {
        return RES_ERROR;
    }

    if (sector == 0)
    {
        memcpy(buff, g_mbr_sector, sizeof(g_mbr_sector));
    }

    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count)
{
    (void)pdrv;

    /* keep the f_mkfs-generated MBR off the disk */
    if (sector == 0)
    {
        memcpy(g_mbr_sector, buff, sizeof(g_mbr_sector));

        if (count == 1)
        {
            return RES_OK;
        }

        buff += 512;
        sector++;
        count--;
    }

    if (vt_pwrite(g_disk, buff, (uint64_t)count * 512, (uint64_t)sector * 512))
    {
        g_write_error = 1;
    }

    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff)
{
    (void)pdrv;

    switch (cmd)
    {
        case CTRL_SYNC:
        {
            break;
        }
        case GET_SECTOR_COUNT:
        {
            *(LBA_t *)buff = g_total_sectors;
            break;
        }
        case GET_SECTOR_SIZE:
        {
            *(WORD *)buff = 512;
            break;
        }
        case GET_BLOCK_SIZE:
        {
            *(DWORD *)buff = 8;
            break;
        }
    }

    return RES_OK;
}
