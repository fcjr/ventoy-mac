/* Standard CRC-32 (IEEE 802.3), as used by GPT. */

#include "ventoy2disk.h"

static uint32_t g_crc_table[256];
static int g_crc_init = 0;

static void crc32_init(void)
{
    uint32_t i, j, c;

    for (i = 0; i < 256; i++)
    {
        c = i;
        for (j = 0; j < 8; j++)
        {
            c = (c & 1) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
        }
        g_crc_table[i] = c;
    }
    g_crc_init = 1;
}

uint32_t vt_crc32(const void *buffer, uint32_t length)
{
    uint32_t i;
    uint32_t crc = 0xFFFFFFFFU;
    const uint8_t *p = (const uint8_t *)buffer;

    if (!g_crc_init)
    {
        crc32_init();
    }

    for (i = 0; i < length; i++)
    {
        crc = g_crc_table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    }

    return crc ^ 0xFFFFFFFFU;
}
