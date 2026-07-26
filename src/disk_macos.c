/* macOS raw-disk access: device naming, size ioctls, unmount, aligned I/O. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/disk.h>

#include "ventoy2disk.h"

/* Accept disk4, /dev/disk4, /dev/rdisk4. Reject partitions (disk4s1). */
static int parse_disk_arg(const char *arg, char *bsdname, size_t len)
{
    const char *p = arg;

    if (strncmp(p, "/dev/", 5) == 0)
    {
        p += 5;
    }
    if (strncmp(p, "rdisk", 5) == 0)
    {
        p += 1;
    }

    if (strncmp(p, "disk", 4) != 0 || !isdigit((unsigned char)p[4]))
    {
        fprintf(stderr, "%s is not a valid disk device\n", arg);
        return 1;
    }

    const char *q = p + 4;
    while (isdigit((unsigned char)*q))
    {
        q++;
    }
    if (*q != 0)
    {
        fprintf(stderr, "%s looks like a partition (slice), please use the whole disk, e.g. /dev/%.*s\n",
                arg, (int)(q - p), p);
        return 1;
    }

    snprintf(bsdname, len, "%s", p);
    return 0;
}

int vt_disk_is_system_disk(const vt_disk *disk)
{
    struct statfs sfs;
    char prefix[64];

    if (statfs("/", &sfs) != 0)
    {
        return 0;
    }

    /* f_mntfromname is e.g. /dev/disk3s1s1 */
    snprintf(prefix, sizeof(prefix), "%ss", disk->dev);
    if (strcmp(sfs.f_mntfromname, disk->dev) == 0 ||
        strncmp(sfs.f_mntfromname, prefix, strlen(prefix)) == 0)
    {
        return 1;
    }

    return 0;
}

int vt_disk_open(const char *arg, vt_disk *disk, bool write)
{
    uint32_t blksize = 0;
    uint64_t blkcount = 0;

    memset(disk, 0, sizeof(*disk));
    disk->fd = -1;

    if (parse_disk_arg(arg, disk->bsdname, sizeof(disk->bsdname)))
    {
        return 1;
    }

    snprintf(disk->dev, sizeof(disk->dev), "/dev/%s", disk->bsdname);
    snprintf(disk->rdev, sizeof(disk->rdev), "/dev/r%s", disk->bsdname);

    disk->fd = open(disk->rdev, write ? O_RDWR : O_RDONLY);
    if (disk->fd < 0)
    {
        fprintf(stderr, "Failed to open %s: %s%s\n", disk->rdev, strerror(errno),
                (errno == EACCES || errno == EPERM) ? " (try running with sudo)" : "");
        return 1;
    }

    if (ioctl(disk->fd, DKIOCGETBLOCKSIZE, &blksize) != 0 ||
        ioctl(disk->fd, DKIOCGETBLOCKCOUNT, &blkcount) != 0)
    {
        fprintf(stderr, "Failed to query disk geometry of %s: %s\n", disk->rdev, strerror(errno));
        vt_disk_close(disk);
        return 1;
    }

    disk->sector_size = blksize;
    disk->sector_count = blkcount;
    disk->size_bytes = (uint64_t)blksize * blkcount;

    return 0;
}

void vt_disk_close(vt_disk *disk)
{
    if (disk->fd >= 0)
    {
        close(disk->fd);
        disk->fd = -1;
    }
}

int vt_disk_unmount(const vt_disk *disk)
{
    char cmd[256];
    int rc;

    snprintf(cmd, sizeof(cmd), "diskutil unmountDisk force %s >/dev/null 2>&1", disk->dev);
    rc = system(cmd);
    if (rc != 0)
    {
        /* Not fatal when nothing was mounted; the caller's writes will fail if
           the kernel still holds the volumes. */
        snprintf(cmd, sizeof(cmd), "diskutil unmountDisk %s >/dev/null 2>&1", disk->dev);
        rc = system(cmd);
    }

    return rc == 0 ? 0 : 1;
}

/* Raw device I/O must be sector-aligned in both offset and length. */
int vt_pread(const vt_disk *disk, void *buf, uint64_t len, uint64_t offset)
{
    ssize_t n;

    if ((len % disk->sector_size) || (offset % disk->sector_size))
    {
        fprintf(stderr, "internal error: unaligned read len=%llu off=%llu\n",
                (unsigned long long)len, (unsigned long long)offset);
        return 1;
    }

    n = pread(disk->fd, buf, len, (off_t)offset);
    if (n != (ssize_t)len)
    {
        fprintf(stderr, "read %s at %llu failed: %s\n", disk->rdev,
                (unsigned long long)offset, strerror(errno));
        return 1;
    }

    return 0;
}

int vt_pwrite(const vt_disk *disk, const void *buf, uint64_t len, uint64_t offset)
{
    ssize_t n;

    if ((len % disk->sector_size) || (offset % disk->sector_size))
    {
        fprintf(stderr, "internal error: unaligned write len=%llu off=%llu\n",
                (unsigned long long)len, (unsigned long long)offset);
        return 1;
    }

    n = pwrite(disk->fd, buf, len, (off_t)offset);
    if (n != (ssize_t)len)
    {
        fprintf(stderr, "write %s at %llu failed: %s\n", disk->rdev,
                (unsigned long long)offset, strerror(errno));
        return 1;
    }

    return 0;
}

int vt_disk_sync(const vt_disk *disk)
{
    if (fcntl(disk->fd, F_FULLFSYNC) != 0)
    {
        fsync(disk->fd);
    }
    return 0;
}
