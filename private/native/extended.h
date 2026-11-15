// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

// Streaming codec implementations used only by the extended native build.
static int brotli_step(BrotliEncoderState *encoder, BrotliDecoderState *decoder,
                       const uint8_t *input, int length, uint8_t *output, int capacity,
                       int action, int *consumed, int *produced) {
    size_t input_left = (size_t)length, output_left = (size_t)capacity;
    int result;
    if (encoder) {
        BrotliEncoderOperation op = action == FINISH ? BROTLI_OPERATION_FINISH :
                                    action == FLUSH ? BROTLI_OPERATION_FLUSH : BROTLI_OPERATION_PROCESS;
        if (!BrotliEncoderCompressStream(encoder, op, &input_left, &input, &output_left, &output, NULL))
            return BAD_DATA;
        result = BrotliEncoderIsFinished(encoder) ||
                 (action == FLUSH && !BrotliEncoderHasMoreOutput(encoder)) ? COMPLETE : CONTINUE;
    } else {
        BrotliDecoderResult status =
            BrotliDecoderDecompressStream(decoder, &input_left, &input, &output_left, &output, NULL);
        if (status == BROTLI_DECODER_RESULT_ERROR) {
            switch (BrotliDecoderGetErrorCode(decoder)) {
                case BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MODES:
                case BROTLI_DECODER_ERROR_ALLOC_TREE_GROUPS:
                case BROTLI_DECODER_ERROR_ALLOC_CONTEXT_MAP:
                case BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_1:
                case BROTLI_DECODER_ERROR_ALLOC_RING_BUFFER_2:
                case BROTLI_DECODER_ERROR_ALLOC_BLOCK_TYPE_TREES:
                    return RESOURCE;
                default:
                    return BAD_DATA;
            }
        }
        result = status == BROTLI_DECODER_RESULT_SUCCESS ? COMPLETE : CONTINUE;
    }
    *consumed = length - (int)input_left;
    *produced = capacity - (int)output_left;
    return result;
}

enum { LZ4_INPUT_CHUNK = 64 * 1024 };

typedef struct {
    LZ4F_cctx *encoder;
    LZ4F_dctx *decoder;
    uint8_t *staging;
    size_t capacity;
    size_t offset;
    size_t end;
    int staged_status;
} lz4_codec;

static void lz4_drop(lz4_codec *state) {
    if (state->encoder) LZ4F_freeCompressionContext(state->encoder);
    if (state->decoder) LZ4F_freeDecompressionContext(state->decoder);
    free(state->staging);
}

static int lz4_open(lz4_codec *state, int encode, int level) {
    if (!encode) return !LZ4F_isError(LZ4F_createDecompressionContext(&state->decoder, LZ4F_VERSION));
    if (LZ4F_isError(LZ4F_createCompressionContext(&state->encoder, LZ4F_VERSION))) return 0;

    LZ4F_preferences_t prefs = {0};
    prefs.frameInfo.blockSizeID = LZ4F_max64KB;
    prefs.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled;
    prefs.compressionLevel = level;
    size_t update_bound = LZ4F_compressBound(LZ4_INPUT_CHUNK, &prefs);
    size_t finish_bound = LZ4F_compressBound(0, &prefs);
    if (LZ4F_isError(update_bound) || LZ4F_isError(finish_bound)) return 0;
    state->capacity = update_bound > finish_bound ? update_bound : finish_bound;
    if (state->capacity < LZ4F_HEADER_SIZE_MAX) state->capacity = LZ4F_HEADER_SIZE_MAX;
    state->staging = malloc(state->capacity);
    if (!state->staging) return 0;

    state->end = LZ4F_compressBegin(state->encoder, state->staging, state->capacity, &prefs);
    return !LZ4F_isError(state->end);
}

static int lz4_error(size_t status) {
    return strcmp(LZ4F_getErrorName(status), "ERROR_allocation_failed") == 0 ? RESOURCE : BAD_DATA;
}

static int lz4_step(lz4_codec *state, const uint8_t *input, int length, uint8_t *output,
                    int capacity, int action, int *consumed, int *produced) {
    if (state->decoder) {
        size_t source = (size_t)length, dest = (size_t)capacity;
        size_t status = LZ4F_decompress(state->decoder, output, &dest, input, &source, NULL);
        if (LZ4F_isError(status)) return lz4_error(status);
        *consumed = (int)source;
        *produced = (int)dest;
        return status == 0 ? COMPLETE : CONTINUE;
    }

    // LZ4F needs room for a worst-case block per call. Stage one bounded block
    // and drain it before accepting more input, including a flush or trailer.
    *consumed = 0;
    if (state->offset == state->end) {
        state->offset = 0;
        state->staged_status = CONTINUE;
        if (length > 0) {
            int chunk = length < LZ4_INPUT_CHUNK ? length : LZ4_INPUT_CHUNK;
            state->end = LZ4F_compressUpdate(state->encoder, state->staging, state->capacity,
                                            input, (size_t)chunk, NULL);
            *consumed = chunk;
        } else if (action == FINISH || action == FLUSH) {
            state->end = action == FINISH
                ? LZ4F_compressEnd(state->encoder, state->staging, state->capacity, NULL)
                : LZ4F_flush(state->encoder, state->staging, state->capacity, NULL);
            state->staged_status = COMPLETE;
        } else {
            state->end = 0;
        }
        if (LZ4F_isError(state->end)) return lz4_error(state->end);
    }

    size_t available = state->end - state->offset;
    size_t count = available < (size_t)capacity ? available : (size_t)capacity;
    if (count) memcpy(output, state->staging + state->offset, count);
    state->offset += count;
    *produced = (int)count;
    return state->offset == state->end ? state->staged_status : CONTINUE;
}
