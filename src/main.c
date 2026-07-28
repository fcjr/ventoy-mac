/* ventoy2disk for macOS -- install Ventoy on a USB drive. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ventoy2disk.h"

#ifndef V2D_VERSION
#define V2D_VERSION "dev"
#endif

static void print_usage(void)
{
    printf("Usage:  ventoy2disk CMD [ OPTION ] /dev/diskN\n");
    printf("  CMD:\n");
    printf("   -i  install Ventoy to diskN (fails if disk already installed with Ventoy)\n");
    printf("   -I  force install Ventoy to diskN (no matter if installed or not)\n");
    printf("   -u  update Ventoy in diskN\n");
    printf("   -l  list Ventoy information in diskN\n");
    printf("\n");
    printf("  OPTION: (optional)\n");
    printf("   -r SIZE_MB  preserve some space at the bottom of the disk (only for install)\n");
    printf("   -s/-S       enable/disable secure boot support (default is enabled)\n");
    printf("   -g          use GPT partition style, default is MBR (only for install)\n");
    printf("   -L LABEL    label of the 1st exfat partition (default is Ventoy)\n");
    printf("   -y          assume yes, no confirmation prompts\n");
    printf("   --pack DIR  use payloads from an extracted ventoy-x.y.z-linux package\n");
    printf("               (default: download the latest release and cache it)\n");
    printf("\n");
    printf("Find your disk with: diskutil list external\n");
}

int main(int argc, char **argv)
{
    int i;
    vt_opts opts;

    /* Keep stdout ordered with stderr when piped (GUI console). */
    setvbuf(stdout, NULL, _IOLBF, 0);

    memset(&opts, 0, sizeof(opts));
    opts.secure_boot = true;
    opts.label = "Ventoy";

    for (i = 1; i < argc; i++)
    {
        const char *arg = argv[i];

        if (strcmp(arg, "-i") == 0)
        {
            opts.mode = 'i';
        }
        else if (strcmp(arg, "-I") == 0)
        {
            opts.mode = 'i';
            opts.force = true;
        }
        else if (strcmp(arg, "-u") == 0)
        {
            opts.mode = 'u';
        }
        else if (strcmp(arg, "-l") == 0)
        {
            opts.mode = 'l';
        }
        else if (strcmp(arg, "-s") == 0)
        {
            opts.secure_boot = true;
            opts.secure_boot_set = true;
        }
        else if (strcmp(arg, "-S") == 0)
        {
            opts.secure_boot = false;
            opts.secure_boot_set = true;
        }
        else if (strcmp(arg, "-g") == 0)
        {
            opts.gpt = true;
        }
        else if (strcmp(arg, "-y") == 0)
        {
            opts.yes = true;
        }
        else if (strcmp(arg, "-L") == 0)
        {
            if (++i >= argc)
            {
                fprintf(stderr, "-L requires a label\n");
                return 1;
            }
            opts.label = argv[i];
        }
        else if (strcmp(arg, "-r") == 0)
        {
            if (++i >= argc)
            {
                fprintf(stderr, "-r requires a size in MB\n");
                return 1;
            }
            opts.reserve_mb = atoi(argv[i]);
            if (opts.reserve_mb <= 0)
            {
                fprintf(stderr, "%s is invalid for reserved space\n", argv[i]);
                return 1;
            }
        }
        else if (strcmp(arg, "--pack") == 0)
        {
            if (++i >= argc)
            {
                fprintf(stderr, "--pack requires a directory\n");
                return 1;
            }
            opts.pack_dir = argv[i];
        }
        else if (strcmp(arg, "-V") == 0 || strcmp(arg, "--version") == 0)
        {
            printf("ventoy2disk %s\n", V2D_VERSION);
            return 0;
        }
        else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0)
        {
            print_usage();
            return 0;
        }
        else if (arg[0] == '-')
        {
            fprintf(stderr, "Unknown option %s\n\n", arg);
            print_usage();
            return 1;
        }
        else
        {
            opts.disk_arg = arg;
        }
    }

    if (!opts.mode || !opts.disk_arg)
    {
        print_usage();
        return 1;
    }

    printf("\n**********************************************\n");
    printf("      ventoy2disk for macOS  (%s)\n", V2D_VERSION);
    printf("      Ventoy: https://www.ventoy.net\n");
    printf("**********************************************\n");

    switch (opts.mode)
    {
        case 'i': return vt_install(&opts);
        case 'u': return vt_update(&opts);
        case 'l': return vt_list(&opts);
    }

    return 1;
}
