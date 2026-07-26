/* Read Ventoy metadata out of the part2 FAT16 filesystem on the raw disk,
 * ported from vtoycli/vtoyfat.c. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fat_filelib.h>

#include "ventoy2disk.h"

static const vt_disk *g_fat_disk = NULL;
static uint64_t g_fat_base_sector = 0;

static int disk_sector_read(uint32 sector, uint8 *buffer, uint32 sector_count)
{
    if (vt_pread(g_fat_disk, buffer, (uint64_t)sector_count * 512,
                 (g_fat_base_sector + sector) * 512))
    {
        return 0;
    }
    return 1;
}

int vt_part2_get_version(const vt_disk *disk, uint64_t part2_start_sector,
                         char *ver, size_t ver_len)
{
    int rc = 1;
    int size = 0;
    char *buf = NULL;
    char *pos = NULL;
    char *end = NULL;
    void *flfile = NULL;

    g_fat_disk = disk;
    g_fat_base_sector = part2_start_sector;

    fl_init();

    if (0 == fl_attach_media(disk_sector_read, NULL))
    {
        flfile = fl_fopen("/grub/grub.cfg", "rb");
        if (flfile)
        {
            fl_fseek(flfile, 0, SEEK_END);
            size = (int)fl_ftell(flfile);
            fl_fseek(flfile, 0, SEEK_SET);

            buf = malloc(size + 1);
            if (buf)
            {
                fl_fread(buf, 1, size, flfile);
                buf[size] = 0;

                pos = strstr(buf, "VENTOY_VERSION=");
                if (pos)
                {
                    pos += strlen("VENTOY_VERSION=");
                    if (*pos == '"')
                    {
                        pos++;
                    }

                    end = pos;
                    while (*end != 0 && *end != '"' && *end != '\r' && *end != '\n')
                    {
                        end++;
                    }
                    *end = 0;

                    snprintf(ver, ver_len, "%s", pos);
                    rc = 0;
                }
                free(buf);
            }

            fl_fclose(flfile);
        }
    }

    fl_shutdown();
    g_fat_disk = NULL;

    return rc;
}

/* returns 1 if secure boot support is enabled (shim chain present) */
int vt_part2_secure_boot_enabled(const vt_disk *disk, uint64_t part2_start_sector)
{
    int enabled = 0;
    void *flfile = NULL;

    g_fat_disk = disk;
    g_fat_base_sector = part2_start_sector;

    fl_init();

    if (0 == fl_attach_media(disk_sector_read, NULL))
    {
        flfile = fl_fopen("/EFI/BOOT/grubx64_real.efi", "rb");
        if (flfile)
        {
            fl_fclose(flfile);
            enabled = 1;
        }
    }

    fl_shutdown();
    g_fat_disk = NULL;

    return enabled;
}
