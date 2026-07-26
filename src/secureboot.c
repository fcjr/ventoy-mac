/* Secure-boot processing of the in-memory part2 image, ported from
 * Ventoy2Disk PhyDrive.c.  With secure boot support enabled (the default)
 * the image is written as-is (shim as BOOTX64.EFI).  With it disabled,
 * the real grub binaries replace the shim chain. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fat_filelib.h>

#include "ventoy2disk.h"

static uint8_t *g_img = NULL;

static int mem_read(uint32 sector, uint8 *buffer, uint32 sector_count)
{
    memcpy(buffer, g_img + (uint64_t)sector * 512, (uint64_t)sector_count * 512);
    return 1;
}

static int mem_write(uint32 sector, uint8 *buffer, uint32 sector_count)
{
    memcpy(g_img + (uint64_t)sector * 512, buffer, (uint64_t)sector_count * 512);
    return 1;
}

static void replace_efi(const char *real_name, const char *boot_name,
                        const char **del_list)
{
    int i;
    int size;
    char *filebuf = NULL;
    void *file = NULL;

    file = fl_fopen(real_name, "rb");
    if (!file)
    {
        return;
    }

    fl_fseek(file, 0, SEEK_END);
    size = (int)fl_ftell(file);
    fl_fseek(file, 0, SEEK_SET);

    filebuf = (char *)malloc(size);
    if (filebuf)
    {
        fl_fread(filebuf, 1, size, file);
    }
    fl_fclose(file);

    for (i = 0; del_list[i]; i++)
    {
        fl_remove(del_list[i]);
    }

    file = fl_fopen(boot_name, "wb");
    if (file)
    {
        if (filebuf)
        {
            fl_fwrite(filebuf, 1, size, file);
        }
        fl_fflush(file);
        fl_fclose(file);
    }

    free(filebuf);
}

int vt_proc_secure_boot(uint8_t *disk_img, bool secure_boot_support)
{
    int rc = 0;
    static const char *x64_del[] = {
        "/EFI/BOOT/BOOTX64.EFI",
        "/EFI/BOOT/grubx64.efi",
        "/EFI/BOOT/grubx64_real.efi",
        "/EFI/BOOT/MokManager.efi",
        "/EFI/BOOT/mmx64.efi",
        "/ENROLL_THIS_KEY_IN_MOKMANAGER.cer",
        "/EFI/BOOT/grub.efi",
        NULL
    };
    static const char *ia32_del[] = {
        "/EFI/BOOT/BOOTIA32.EFI",
        "/EFI/BOOT/grubia32.efi",
        "/EFI/BOOT/grubia32_real.efi",
        "/EFI/BOOT/mmia32.efi",
        NULL
    };

    if (secure_boot_support)
    {
        return 0;
    }

    g_img = disk_img;

    fl_init();

    if (0 == fl_attach_media(mem_read, mem_write))
    {
        replace_efi("/EFI/BOOT/grubx64_real.efi", "/EFI/BOOT/BOOTX64.EFI", x64_del);
        replace_efi("/EFI/BOOT/grubia32_real.efi", "/EFI/BOOT/BOOTIA32.EFI", ia32_del);
    }
    else
    {
        rc = 1;
    }

    fl_shutdown();
    g_img = NULL;

    return rc;
}
