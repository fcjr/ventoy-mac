/* Locate, download and load the Ventoy release payloads.
 *
 * The install payloads (boot/boot.img, boot/core.img.xz,
 * ventoy/ventoy.disk.img.xz) are taken from the official release package
 * ventoy-x.y.z-linux.tar.gz, downloaded from GitHub and cached under
 * ~/Library/Caches/com.leftshift.ventoy/.  A local package directory can
 * be supplied instead with --pack. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <pwd.h>

#include "ventoy2disk.h"

#define VENTOY_RELEASE_API "https://api.github.com/repos/ventoy/Ventoy/releases/latest"
#define CORE_IMG_CAP  SIZE_1MB

static const char *cache_root(char *buf, size_t len)
{
    const char *home = getenv("HOME");

    if (!home || !home[0])
    {
        struct passwd *pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : "/tmp";
    }

    snprintf(buf, len, "%s/Library/Caches/com.leftshift.ventoy", home);
    return buf;
}

static int dir_has_payloads(const char *dir)
{
    char path[1200];
    static const char *files[] = {
        "boot/boot.img", "boot/core.img.xz", "ventoy/ventoy.disk.img.xz", NULL
    };

    for (int i = 0; files[i]; i++)
    {
        snprintf(path, sizeof(path), "%s/%s", dir, files[i]);
        if (access(path, R_OK) != 0)
        {
            return 0;
        }
    }
    return 1;
}

/* "v1.1.17" from the GitHub API response, NULL on failure */
static int fetch_latest_tag(char *tag, size_t len)
{
    FILE *fp;
    char line[4096];
    char *pos, *end;
    int found = 1;

    fp = popen("/usr/bin/curl -sfL --max-time 30 " VENTOY_RELEASE_API, "r");
    if (!fp)
    {
        return 1;
    }

    while (fgets(line, sizeof(line), fp))
    {
        pos = strstr(line, "\"tag_name\"");
        if (!pos)
        {
            continue;
        }
        pos = strchr(pos + 10, '"');
        if (!pos)
        {
            continue;
        }
        pos++;
        end = strchr(pos, '"');
        if (!end || (size_t)(end - pos) >= len)
        {
            continue;
        }
        memcpy(tag, pos, end - pos);
        tag[end - pos] = 0;
        found = 0;
        break;
    }

    pclose(fp);
    return found;
}

/* newest cached ventoy-* dir with valid payloads, for offline fallback */
static int newest_cached(const char *root, char *dir, size_t len)
{
    DIR *dp;
    struct dirent *de;
    char best[256] = { 0 };
    char cand[1400];

    dp = opendir(root);
    if (!dp)
    {
        return 1;
    }

    while ((de = readdir(dp)) != NULL)
    {
        if (strncmp(de->d_name, "ventoy-", 7) != 0)
        {
            continue;
        }
        snprintf(cand, sizeof(cand), "%s/%s", root, de->d_name);
        if (!dir_has_payloads(cand))
        {
            continue;
        }
        if (strcmp(de->d_name, best) > 0)
        {
            snprintf(best, sizeof(best), "%s", de->d_name);
        }
    }
    closedir(dp);

    if (!best[0])
    {
        return 1;
    }

    snprintf(dir, len, "%s/%s", root, best);
    return 0;
}

static int download_release(const char *root, const char *tag, char *dir, size_t len)
{
    char cmd[2048];
    char tarball[1400];
    const char *ver = (tag[0] == 'v') ? tag + 1 : tag;

    snprintf(dir, len, "%s/ventoy-%s", root, ver);
    if (dir_has_payloads(dir))
    {
        return 0;
    }

    printf("Downloading Ventoy %s release payloads ...\n", tag);

    snprintf(cmd, sizeof(cmd), "mkdir -p '%s'", root);
    if (system(cmd) != 0)
    {
        return 1;
    }

    snprintf(tarball, sizeof(tarball), "%s/ventoy-%s-linux.tar.gz", root, ver);
    snprintf(cmd, sizeof(cmd),
             "/usr/bin/curl -sfL --max-time 300 -o '%s' "
             "'https://github.com/ventoy/Ventoy/releases/download/%s/ventoy-%s-linux.tar.gz'",
             tarball, tag, ver);
    if (system(cmd) != 0)
    {
        fprintf(stderr, "Failed to download Ventoy release %s\n", tag);
        unlink(tarball);
        return 1;
    }

    snprintf(cmd, sizeof(cmd), "/usr/bin/tar -xzf '%s' -C '%s'", tarball, root);
    if (system(cmd) != 0)
    {
        fprintf(stderr, "Failed to extract %s\n", tarball);
        unlink(tarball);
        return 1;
    }
    unlink(tarball);

    if (!dir_has_payloads(dir))
    {
        fprintf(stderr, "Release package layout unexpected at %s\n", dir);
        return 1;
    }

    printf("Payloads cached at %s\n", dir);
    return 0;
}

int vt_pack_locate(const char *pack_dir, vt_pack *pack)
{
    char root[1024];
    char tag[64];

    memset(pack, 0, sizeof(*pack));

    if (pack_dir)
    {
        if (!dir_has_payloads(pack_dir))
        {
            fprintf(stderr, "%s does not contain Ventoy payloads (boot/boot.img etc.)\n", pack_dir);
            return 1;
        }
        snprintf(pack->dir, sizeof(pack->dir), "%s", pack_dir);
        return 0;
    }

    cache_root(root, sizeof(root));

    if (fetch_latest_tag(tag, sizeof(tag)) == 0)
    {
        if (download_release(root, tag, pack->dir, sizeof(pack->dir)) == 0)
        {
            return 0;
        }
    }

    if (newest_cached(root, pack->dir, sizeof(pack->dir)) == 0)
    {
        printf("Using cached payloads at %s\n", pack->dir);
        return 0;
    }

    fprintf(stderr, "Could not fetch Ventoy release payloads (network down?) and no cache found.\n"
                    "You can pass --pack <dir> pointing to an extracted ventoy-x.y.z-linux package.\n");
    return 1;
}

static int read_file(const char *path, uint8_t **buf, size_t *len)
{
    FILE *fp;
    long size;

    fp = fopen(path, "rb");
    if (!fp)
    {
        fprintf(stderr, "Failed to open %s\n", path);
        return 1;
    }

    fseek(fp, 0, SEEK_END);
    size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    *buf = malloc(size);
    if (!*buf || fread(*buf, 1, size, fp) != (size_t)size)
    {
        fprintf(stderr, "Failed to read %s\n", path);
        fclose(fp);
        free(*buf);
        *buf = NULL;
        return 1;
    }

    fclose(fp);
    *len = size;
    return 0;
}

int vt_pack_load(vt_pack *pack)
{
    char path[1200];
    uint8_t *xzbuf = NULL;
    size_t xzlen = 0;
    size_t rawlen = 0;
    FILE *fp;

    /* boot.img: exactly 512 bytes */
    snprintf(path, sizeof(path), "%s/boot/boot.img", pack->dir);
    fp = fopen(path, "rb");
    if (!fp || fread(pack->boot_img, 1, 512, fp) != 512)
    {
        fprintf(stderr, "Failed to read %s\n", path);
        if (fp) fclose(fp);
        return 1;
    }
    fclose(fp);

    /* core.img.xz -> up to 1MB, zero-padded */
    snprintf(path, sizeof(path), "%s/boot/core.img.xz", pack->dir);
    if (read_file(path, &xzbuf, &xzlen))
    {
        return 1;
    }
    pack->core_img = calloc(1, CORE_IMG_CAP);
    if (!pack->core_img || vt_unxz(xzbuf, xzlen, pack->core_img, CORE_IMG_CAP, &rawlen))
    {
        fprintf(stderr, "Failed to decompress %s\n", path);
        free(xzbuf);
        return 1;
    }
    free(xzbuf);
    pack->core_len = rawlen;

    /* ventoy.disk.img.xz -> exactly 32MB */
    snprintf(path, sizeof(path), "%s/ventoy/ventoy.disk.img.xz", pack->dir);
    if (read_file(path, &xzbuf, &xzlen))
    {
        return 1;
    }
    pack->disk_img = malloc(VENTOY_EFI_PART_SIZE);
    if (!pack->disk_img ||
        vt_unxz(xzbuf, xzlen, pack->disk_img, VENTOY_EFI_PART_SIZE, &rawlen) ||
        rawlen != VENTOY_EFI_PART_SIZE)
    {
        fprintf(stderr, "Failed to decompress %s (got %zu bytes)\n", path, rawlen);
        free(xzbuf);
        return 1;
    }
    free(xzbuf);

    /* version (optional) */
    snprintf(path, sizeof(path), "%s/ventoy/version", pack->dir);
    fp = fopen(path, "r");
    if (fp)
    {
        if (fgets(pack->version, sizeof(pack->version), fp))
        {
            pack->version[strcspn(pack->version, "\r\n")] = 0;
        }
        fclose(fp);
    }
    if (!pack->version[0])
    {
        snprintf(pack->version, sizeof(pack->version), "unknown");
    }

    return 0;
}

void vt_pack_free(vt_pack *pack)
{
    free(pack->core_img);
    free(pack->disk_img);
    pack->core_img = NULL;
    pack->disk_img = NULL;
}
