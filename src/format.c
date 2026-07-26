/* exFAT format of partition 1 via FatFs f_mkfs, as upstream Ventoy2Disk. */

#include <stdio.h>
#include <string.h>

#include "ff.h"
#include "ventoy2disk.h"

int vt_format_part1_exfat(const vt_disk *disk, uint64_t part1_end_sector,
                          const char *label)
{
    MKFS_PARM option;
    FRESULT ret;
    FATFS fs;
    char label_buf[64];
    static uint8_t work_buf[8 * 1024 * 1024];

    memset(&option, 0, sizeof(option));
    option.fmt = FM_EXFAT;
    option.n_fat = 1;
    option.align = 8;
    option.n_root = 1;

    /* <= 32GB: 32KB clusters, otherwise 128KB clusters */
    if (disk->size_bytes / 1024 / 1024 / 1024 <= 32)
    {
        option.au_size = 32768;
    }
    else
    {
        option.au_size = 131072;
    }

    /* FatFs drive = sectors 0 .. end of part1; volume lands at 2048 */
    vt_ff_set_target(disk, part1_end_sector);

    ret = f_mkfs("0:", &option, work_buf, sizeof(work_buf));
    if (ret != FR_OK)
    {
        fprintf(stderr, "exFAT format failed (FatFs error %d)\n", (int)ret);
        return 1;
    }

    if (vt_ff_write_error())
    {
        fprintf(stderr, "exFAT format failed: disk write error\n");
        return 1;
    }

    ret = f_mount(&fs, "0:", 1);
    if (ret != FR_OK)
    {
        fprintf(stderr, "mount after format failed (FatFs error %d)\n", (int)ret);
        return 1;
    }

    snprintf(label_buf, sizeof(label_buf), "0:%s", label);
    ret = f_setlabel(label_buf);
    if (ret != FR_OK)
    {
        fprintf(stderr, "set label failed (FatFs error %d)\n", (int)ret);
    }

    f_unmount("0:");

    return vt_ff_write_error() ? 1 : 0;
}
