// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";

/** @brief Interoperable single-stream codec format. */
pub enum CompressionFormat {
  Gzip,
  Zstandard
}

/** @brief Admission, resource or input-stream failure. */
pub enum CompressionError {
  InvalidArgument,
  Closed,
  Corrupt,
  Truncated,
  LimitExceeded,
  ResourceExhausted,
  TrailingData,
  Io
}

/** @brief Exact input prefix consumed and one owned output block. */
pub struct CompressionProgress {
  consumed: int32;
  output: ByteBuffer;
  complete: bool;
}

/** @brief Exact byte counts from a step into caller-owned storage. */
pub struct CompressionTransfer {
  consumed: int32;
  produced: int32;
  complete: bool;
}

/** @brief Move-only compression or decompression cursor. */
pub struct CompressionStream;

/** @brief Encode a complete buffer as one gzip member or Zstandard frame. */
pub static method(CompressionStream) Compress(
  format: CompressionFormat, input: ref ByteBuffer
) -> Result<ByteBuffer, CompressionError>;

/** @brief Decode exactly one member or frame into an owned buffer with an explicit byte limit.
 * @note Trailing bytes, including concatenated members or frames, return TrailingData. */
pub static method(CompressionStream) Decompress(
  format: CompressionFormat, input: ref ByteBuffer, max_output: uint64
) -> Result<ByteBuffer, CompressionError>;

/** @brief Decode one or more concatenated members or frames of the specified format.
 * @note Limits apply to aggregate output and number of members, including empty
 * members. Any malformed or truncated member fails the entire operation. */
pub static method(CompressionStream) DecompressAll(
  format: CompressionFormat, input: ref ByteBuffer, max_output: uint64, max_members: int32
) -> Result<ByteBuffer, CompressionError>;

/** @brief Start a default-level encoder. */
pub static method(CompressionStream) Encode(format: CompressionFormat) -> Result<CompressionStream, CompressionError>;

/** @brief Start an encoder at an explicit level. Gzip accepts 0..9 and Zstandard accepts 1..22. */
pub static method(CompressionStream) EncodeLevel(
  format: CompressionFormat, level: int32
) -> Result<CompressionStream, CompressionError>;

/** @brief Encoded bytes emitted by one nonterminal flush step. */
pub struct CompressionFlush {
  output: ByteBuffer;
  drained: bool;
}

/** @brief Emit pending encoder bytes without ending the member or frame.
 * @note Repeat until drained before calling Push. Always resubmit any unconsumed
 * input from the preceding Push before flushing. */
pub method(CompressionStream) Flush() -> Result<CompressionFlush, CompressionError>;

/** @brief Start a decoder with an explicit total output byte budget, including zero. */
pub static method(CompressionStream) Decode(
  format: CompressionFormat, max_output: uint64
) -> Result<CompressionStream, CompressionError>;

/** @brief Start Zstandard decoding with an explicit window and total output limit.
 * @note window_log is 10..27 and caps the advertised window at 2^window_log bytes.
 * An oversized frame returns LimitExceeded. Provider overhead is additional.
 * As with Decode, resubmit the unconsumed input reported by Push. */
pub static method(CompressionStream) DecodeZstandard(
  max_output: uint64, window_log: int32
) -> Result<CompressionStream, CompressionError>;

/** @brief Start a Zstandard encoder with a copied dictionary, 8 bytes to 1 MiB. */
pub static method(CompressionStream) EncodeZstandardDictionary(
  dictionary: ref ByteBuffer, level: int32
) -> Result<CompressionStream, CompressionError>;

/** @brief Start a bounded Zstandard decoder with the same dictionary used for encoding.
 * @note The provider copies the dictionary. Its storage is additional to the window limit. */
pub static method(CompressionStream) DecodeZstandardDictionary(
  dictionary: ref ByteBuffer, max_output: uint64, window_log: int32
) -> Result<CompressionStream, CompressionError>;

/** @brief Active codec state has one owner. */
pub method(CompressionStream) operator copy() -> CompressionStream = delete;

/** @brief Move the cursor and invalidate the source. */
pub method(CompressionStream) operator move() -> CompressionStream;

/** @brief Release the codec provider state. */
pub method(CompressionStream) operator drop() -> void;

/** @brief Consume bytes and emit up to 16 KiB of output per call.
 * @note Resubmit unconsumed input. Set end_of_input for the final block and all
 * subsequent draining calls. Complete stops at the end of one member/frame.
 * Use the reported count to handle trailing bytes. Failures retire the stream. */
pub method(CompressionStream) Push(
  input: ref ByteBuffer, offset: int32, end_of_input: bool
) -> Result<CompressionProgress, CompressionError>;

/** @brief Process a bounded range of a reusable input buffer.
 * @note consumed is relative to offset. An invalid range leaves the stream usable. */
pub method(CompressionStream) PushRange(
  input: ref ByteBuffer, offset: int32, length: int32, end_of_input: bool
) -> Result<CompressionProgress, CompressionError>;

/** @brief Process an input range directly into nonempty caller-owned storage.
 * @note Output storage must be disjoint from the input. Only the produced prefix
 * is valid on success. On failure, the destination may change. Resubmit unconsumed
 * input and keep end_of_input set once final draining starts. */
pub method(CompressionStream) PushInto(
  input: ref ByteBuffer, offset: int32, length: int32, output: MutableByteView, end_of_input: bool
) -> Result<CompressionTransfer, CompressionError>;

/** @brief Advance directly between disjoint borrowed buffers.
 * @note Input size must fit int32. Reoffer bytes that were not consumed. */
pub method(CompressionStream) PushBytes(
  input: ByteView, output: MutableByteView, end_of_input: bool
) -> Result<CompressionTransfer, CompressionError>;

/** @brief Owns incremental decoding of concatenated gzip members or Zstandard frames. */
pub struct CompressionSequence;
pub method(CompressionSequence) operator copy() -> CompressionSequence = delete;
pub method(CompressionSequence) operator move() -> CompressionSequence;

/** @brief Create a sequence decoder with total output and member limits. */
pub static method(CompressionSequence) New(
  format: CompressionFormat, max_output: uint64, max_members: int32
) -> Result<CompressionSequence, CompressionError>;

/** @brief Advance decoding into a caller buffer, retaining at most one active codec.
 * @note complete denotes the end of the whole sequence and requires end_of_input.
 * An exact member boundary before then is a valid pause. Resubmit the input suffix
 * after each step. Zero bytes for the whole input are Truncated. */
pub method(CompressionSequence) PushBytes(
  input: ByteView, output: MutableByteView, end_of_input: bool
) -> Result<CompressionTransfer, CompressionError>;

/** @brief Decode from one blocking Stream into another using bounded scratch.
 * @note Streams stay open. A read or write failure returns Io and may leave
 * partial output. Flush the destination when required by its contract. */
pub static method(CompressionSequence) DecodeStream(
  format: CompressionFormat, source: ref mut Stream, destination: ref mut Stream,
  max_output: uint64, max_members: int32
) -> Result<Unit, CompressionError>;
