// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

#include <stdint.h>
#include <stdlib.h>
#include <zlib.h>
#include <zstd.h>
#include <zstd_errors.h>

enum { CONTINUE, COMPLETE, BAD_DATA, RESOURCE, WINDOW_LIMIT };
enum { GZIP = 1, ZSTANDARD = 2 };
enum { PUSH, FINISH, FLUSH };

typedef struct {
    int format;
    int encode;
    int split_header;
    z_stream gzip;
    ZSTD_CCtx *encoder;
    ZSTD_DCtx *decoder;
} codec;

void nyra_compress_drop(codec *state) {
    if (!state) return;
    if (state->format == GZIP) {
        if (state->encode) deflateEnd(&state->gzip);
        else inflateEnd(&state->gzip);
    } else {
        ZSTD_freeCCtx(state->encoder);
        ZSTD_freeDCtx(state->decoder);
    }
    free(state);
}

codec *nyra_compress_open(int format, int encode, int level, int window_log) {
    codec *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->format = format;
    state->encode = encode;
    if (format == GZIP) {
        int status = encode ? deflateInit2(&state->gzip, level, Z_DEFLATED,
                                           15 + 16, 8, Z_DEFAULT_STRATEGY)
                            : inflateInit2(&state->gzip, 15 + 16);
        if (status == Z_OK) return state;
    } else if (format == ZSTANDARD) {
        if (encode) {
            state->encoder = ZSTD_createCCtx();
            if (state->encoder &&
                !ZSTD_isError(ZSTD_CCtx_setParameter(state->encoder, ZSTD_c_compressionLevel, level))) {
                return state;
            }
        } else {
            state->decoder = ZSTD_createDCtx();
            state->split_header = window_log != 0;
            if (state->decoder &&
                !ZSTD_isError(ZSTD_DCtx_setParameter(state->decoder, ZSTD_d_windowLogMax, window_log ? window_log : 27))) {
                return state;
            }
        }
    }
    nyra_compress_drop(state);
    return NULL;
}

int nyra_compress_step(codec *state, const uint8_t *input, int length, uint8_t *output,
                       int capacity, int action, int *consumed, int *produced) {
    if (state->format == GZIP) {
        z_stream *stream = &state->gzip;
        stream->next_in = (Bytef *)input;
        stream->avail_in = (uInt)length;
        stream->next_out = output;
        stream->avail_out = (uInt)capacity;
        int flush = action == FLUSH ? Z_SYNC_FLUSH : action == FINISH ? Z_FINISH : Z_NO_FLUSH;
        int status = state->encode ? deflate(stream, flush) : inflate(stream, Z_NO_FLUSH);
        *consumed = length - (int)stream->avail_in;
        *produced = capacity - (int)stream->avail_out;
        stream->next_in = NULL;
        stream->next_out = NULL;
        if (status == Z_STREAM_END) return COMPLETE;
        if (status == Z_MEM_ERROR) return RESOURCE;
        if (action == FLUSH && (status == Z_OK || status == Z_BUF_ERROR) && stream->avail_out != 0)
            return COMPLETE;
        return status == Z_OK || status == Z_BUF_ERROR ? CONTINUE : BAD_DATA;
    }

    size_t admitted = (size_t)length;
    if (state->split_header && length > 0) {
        // Give the streaming decoder an incomplete header to disable its direct whole-frame path.
        if (admitted > 5) admitted = 5;
        state->split_header = 0;
    }
    ZSTD_inBuffer source = {input, admitted, 0};
    ZSTD_outBuffer dest = {output, (size_t)capacity, 0};
    ZSTD_EndDirective directive = action == FLUSH ? ZSTD_e_flush : action == FINISH ? ZSTD_e_end : ZSTD_e_continue;
    size_t status = state->encode
        ? ZSTD_compressStream2(state->encoder, &dest, &source, directive)
        : ZSTD_decompressStream(state->decoder, &dest, &source);
    if (ZSTD_isError(status)) {
        ZSTD_ErrorCode error = ZSTD_getErrorCode(status);
        if (error == ZSTD_error_frameParameter_windowTooLarge) return WINDOW_LIMIT;
        if (error == ZSTD_error_memory_allocation) return RESOURCE;
        return BAD_DATA;
    }
    *consumed = (int)source.pos;
    *produced = (int)dest.pos;
    return status == 0 && (!state->encode || action != PUSH) ? COMPLETE : CONTINUE;
}

int nyra_compress_dictionary(codec *state, const uint8_t *bytes, int length) {
    size_t status = state->encode
        ? ZSTD_CCtx_loadDictionary(state->encoder, bytes, (size_t)length)
        : ZSTD_DCtx_loadDictionary(state->decoder, bytes, (size_t)length);
    // Raw dictionaries have no ID in the frame; check the decoded bytes as well.
    if (!ZSTD_isError(status) && state->encode)
        status = ZSTD_CCtx_setParameter(state->encoder, ZSTD_c_checksumFlag, 1);
    if (!ZSTD_isError(status)) return CONTINUE;
    return ZSTD_getErrorCode(status) == ZSTD_error_memory_allocation ? RESOURCE : BAD_DATA;
}
