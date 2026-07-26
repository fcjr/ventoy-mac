/* Single-call xz decompression via xz-embedded. */

#include <stdio.h>
#include "ventoy2disk.h"
#include "xz.h"

int vt_unxz(const uint8_t *in, size_t in_size, uint8_t *out, size_t out_cap,
            size_t *out_len)
{
    struct xz_dec *dec;
    struct xz_buf buf;
    enum xz_ret ret;
    static int crc_init = 0;

    if (!crc_init)
    {
        xz_crc32_init();
        crc_init = 1;
    }

    dec = xz_dec_init(XZ_SINGLE, 0);
    if (!dec)
    {
        return 1;
    }

    buf.in = in;
    buf.in_pos = 0;
    buf.in_size = in_size;
    buf.out = out;
    buf.out_pos = 0;
    buf.out_size = out_cap;

    ret = xz_dec_run(dec, &buf);
    xz_dec_end(dec);

    if (ret != XZ_STREAM_END)
    {
        fprintf(stderr, "xz decompression failed (code %d)\n", (int)ret);
        return 1;
    }

    *out_len = buf.out_pos;
    return 0;
}
