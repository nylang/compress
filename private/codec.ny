// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns codec resources and enforces the total decompressed byte budget. */
module StreamingCompression;
import "stdlib:stdlib.ny";
import "interface/compress.ni";

@extern("C") func nyra_compress_open(format: int32, encode: int32) -> *mut int8;
@extern("C") func nyra_compress_drop(state: *mut int8) -> void;
@extern("C") func nyra_compress_step(
  state: *mut int8, input: *const uint8, length: int32, output: *mut uint8, capacity: int32,
  finish: int32, consumed: *mut int32, produced: *mut int32
) -> int32;

constexpr kCompressionBlock: int32 = 16384;

/** @brief Move-only hosted codec state with an output budget in decode mode. */
pub struct CompressionStream {
  raw: *mut int8;
  decoding: bool;
  remaining: uint64;
  ending: bool;
}

static method(CompressionStream) Open(
  format: CompressionFormat, decoding: bool, budget: uint64
) -> Result<CompressionStream, CompressionError> {
  let kind: int32 = format == CompressionFormat.Gzip ? 1 : 2;
  let encode: int32 = decoding ? 0 : 1;
  let raw = nyra_compress_open(kind, encode);
  if raw == nil {
    return CompressionError.ResourceExhausted;
  }

  return CompressionStream{raw: raw, decoding: decoding, remaining: budget};
}

pub static method(CompressionStream) Encode(format: CompressionFormat) -> Result<CompressionStream, CompressionError> {
  return CompressionStream.Open(format, false, 0u64);
}

pub static method(CompressionStream) Decode(
  format: CompressionFormat, max_output: uint64
) -> Result<CompressionStream, CompressionError> {
  return CompressionStream.Open(format, true, max_output);
}

pub static method(CompressionStream) Compress(
  format: CompressionFormat, input: ref ByteBuffer
) -> Result<ByteBuffer, CompressionError> {
  var opened = CompressionStream.Encode(format);
  if opened.IsErr() {
    return opened.get_if<CompressionError>() as CompressionError;
  }

  var codec = move(opened.get_if<CompressionStream>() as CompressionStream);
  return codec.Collect(input);
}

pub static method(CompressionStream) Decompress(
  format: CompressionFormat, input: ref ByteBuffer, max_output: uint64
) -> Result<ByteBuffer, CompressionError> {
  var opened = CompressionStream.Decode(format, max_output);
  if opened.IsErr() {
    return opened.get_if<CompressionError>() as CompressionError;
  }

  var codec = move(opened.get_if<CompressionStream>() as CompressionStream);
  return codec.Collect(input);
}

// Keep output private until the provider has consumed exactly one complete stream.
method(CompressionStream) Collect(input: ref ByteBuffer) -> Result<ByteBuffer, CompressionError> {
  var output = ByteBuffer.New();
  var offset: int32 = 0;
  while true {
    let step = self.Push(input, offset, true);
    if step.IsErr() {
      return step.get_if<CompressionError>() as CompressionError;
    }

    let progress = step.get_if<CompressionProgress>() as CompressionProgress;
    offset += progress.consumed;
    if progress.complete && offset != input.Len() {
      return CompressionError.TrailingData;
    }
    if output.Write(progress.output.Data(), progress.output.Len() as intptr).IsErr() {
      return CompressionError.ResourceExhausted;
    }
    if progress.complete {
      return output;
    }
    if progress.consumed == 0 && progress.output.Len() == 0 {
      return CompressionError.Corrupt;
    }
  }

  return CompressionError.Corrupt;
}

pub method(CompressionStream) operator move() -> CompressionStream {
  let raw = self.raw;
  let decoding = self.decoding;
  let remaining = self.remaining;
  let ending = self.ending;
  self.raw = nil;

  return CompressionStream{raw: raw, decoding: decoding, remaining: remaining, ending: ending};
}

pub method(CompressionStream) operator drop() -> void {
  self.Close();
}

method(CompressionStream) Close() -> void {
  if self.raw != nil {
    nyra_compress_drop(self.raw);
    self.raw = nil;
  }
}

pub method(CompressionStream) Push(
  input: ref ByteBuffer, offset: int32, end_of_input: bool
) -> Result<CompressionProgress, CompressionError> {
  let length = offset >= 0 && offset <= input.Len() ? input.Len() - offset : 0;
  return self.PushRange(input, offset, length, end_of_input);
}

pub method(CompressionStream) PushRange(
  input: ref ByteBuffer, offset: int32, length: int32, end_of_input: bool
) -> Result<CompressionProgress, CompressionError> {
  if self.raw == nil {
    return CompressionError.Closed;
  }
  if offset < 0 || offset > input.Len() || length < 0 || length > input.Len() - offset ||
      (self.ending && !end_of_input) {
    return CompressionError.InvalidArgument;
  }

  self.ending = end_of_input;
  var block: <uint8>[16384] = <uint8>[16384]{};
  var consumed: int32 = 0;
  var produced: int32 = 0;
  var capacity: int32 = kCompressionBlock;
  if self.decoding && self.remaining < kCompressionBlock as uint64 {
    // One probe byte distinguishes a trailer at the exact limit from more decoded data.
    capacity = (self.remaining as int32) + 1;
  }

  let address = (input.Data() as intptr) + (offset as intptr);
  let finish: int32 = end_of_input ? 1 : 0;
  let status = nyra_compress_step(
    self.raw, address as *const uint8, length, &mut block[0], capacity,
    finish, &mut consumed, &mut produced
  );
  if status > 1 {
    self.Close();
    return status == 3 ? CompressionError.ResourceExhausted : CompressionError.Corrupt;
  }
  if self.decoding {
    if (produced as uint64) > self.remaining {
      self.Close();
      return CompressionError.LimitExceeded;
    }
    self.remaining -= produced as uint64;
    if end_of_input && status == 0 && consumed == 0 && produced == 0 {
      self.Close();
      return CompressionError.Truncated;
    }
  }

  var output = ByteBuffer.New();
  if output.Write(&block[0], produced as intptr).IsErr() {
    self.Close();
    return CompressionError.ResourceExhausted;
  }
  if status == 1 {
    self.Close();
  }

  return CompressionProgress{consumed: consumed, output: output, complete: status == 1};
}
