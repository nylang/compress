// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns codec resources and enforces the total decompressed byte budget. */
module StreamingCompression;
import "stdlib:stdlib.ny";
import "interface/compress.ni";

@extern("C") func nyra_compress_open(format: int32, encode: int32, level: int32, window_log: int32) -> *mut int8;
@extern("C") func nyra_compress_available(format: int32) -> int32;
@extern("C") func nyra_compress_drop(state: *mut int8) -> void;
@extern("C") func nyra_compress_dictionary(state: *mut int8, data: *const uint8, size: int32) -> int32;
@extern("C") func nyra_compress_step(
  state: *mut int8, input: *const uint8, length: int32, output: *mut uint8, capacity: int32,
  finish: int32, consumed: *mut int32, produced: *mut int32
) -> int32;

constexpr kCompressionBlock: int32 = 16384;
constexpr kCompressionFlush: int32 = 2;

/** @brief Move-only hosted codec state with an output budget in decode mode. */
pub struct CompressionStream {
  raw: *mut int8;
  decoding: bool;
  remaining: uint64;
  ending: bool;
  flushing: bool;
}

static method(CompressionStream) Open(
  format: CompressionFormat, decoding: bool, budget: uint64, level: int32, window_log: int32
) -> Result<CompressionStream, CompressionError> {
  let kind = CompressionStream.NativeFormat(format);
  if nyra_compress_available(kind) == 0 {
    return CompressionError.Unsupported;
  }

  let encode: int32 = decoding ? 0 : 1;
  let raw = nyra_compress_open(kind, encode, level, window_log);
  if raw == nil {
    return CompressionError.ResourceExhausted;
  }

  return CompressionStream{raw: raw, decoding: decoding, remaining: budget};
}

static method(CompressionStream) NativeFormat(format: CompressionFormat) -> int32 {
  if format == CompressionFormat.Gzip {
    return 1;
  }
  if format == CompressionFormat.Zstandard {
    return 2;
  }
  if format == CompressionFormat.Brotli {
    return 3;
  }
  if format == CompressionFormat.Lz4Frame {
    return 4;
  }

  return 0;
}

pub static method(CompressionStream) IsAvailable(format: CompressionFormat) -> bool {
  return nyra_compress_available(CompressionStream.NativeFormat(format)) != 0;
}

pub static method(CompressionStream) Encode(format: CompressionFormat) -> Result<CompressionStream, CompressionError> {
  var level: int32 = 0;
  if format == CompressionFormat.Gzip {
    level = -1;
  } else if format == CompressionFormat.Brotli {
    level = 5;
  }

  return CompressionStream.Open(format, false, 0u64, level, 0);
}

pub static method(CompressionStream) EncodeLevel(
  format: CompressionFormat, level: int32
) -> Result<CompressionStream, CompressionError> {
  var valid: bool = false;
  if format == CompressionFormat.Gzip {
    valid = level >= 0 && level <= 9;
  } else if format == CompressionFormat.Zstandard {
    valid = level >= 1 && level <= 22;
  } else if format == CompressionFormat.Brotli {
    valid = level >= 0 && level <= 11;
  } else if format == CompressionFormat.Lz4Frame {
    valid = level >= 0 && level <= 12;
  }
  if !valid {
    return CompressionError.InvalidArgument;
  }

  return CompressionStream.Open(format, false, 0u64, level, 0);
}

pub static method(CompressionStream) Decode(
  format: CompressionFormat, max_output: uint64
) -> Result<CompressionStream, CompressionError> {
  return CompressionStream.Open(format, true, max_output, 0, 0);
}

pub static method(CompressionStream) DecodeZstandard(
  max_output: uint64, window_log: int32
) -> Result<CompressionStream, CompressionError> {
  if window_log < 10 || window_log > 27 {
    return CompressionError.InvalidArgument;
  }

  return CompressionStream.Open(CompressionFormat.Zstandard, true, max_output, 0, window_log);
}

pub static method(CompressionStream) EncodeZstandardDictionary(
  dictionary: ref ByteBuffer, level: int32
) -> Result<CompressionStream, CompressionError> {
  return CompressionStream.OpenDictionary(dictionary, level, false, 0u64, 0);
}

pub static method(CompressionStream) DecodeZstandardDictionary(
  dictionary: ref ByteBuffer, max_output: uint64, window_log: int32
) -> Result<CompressionStream, CompressionError> {
  if window_log < 10 || window_log > 27 {
    return CompressionError.InvalidArgument;
  }

  return CompressionStream.OpenDictionary(dictionary, 0, true, max_output, window_log);
}

static method(CompressionStream) OpenDictionary(
  dictionary: ref ByteBuffer, level: int32, decoding: bool, max_output: uint64, window_log: int32
) -> Result<CompressionStream, CompressionError> {
  if dictionary.Len() < 8 || dictionary.Len() > 1048576 || (!decoding && (level < 1 || level > 22)) {
    return CompressionError.InvalidArgument;
  }

  var opened = CompressionStream.Open(CompressionFormat.Zstandard, decoding, max_output, level, window_log);
  if opened.IsErr() {
    return opened.get_if<CompressionError>() as CompressionError;
  }
  var stream = move(opened.get_if<CompressionStream>() as CompressionStream);
  let status = nyra_compress_dictionary(stream.raw, dictionary.Data(), dictionary.Len());
  if status != 0 {
    return status == 3 ? CompressionError.ResourceExhausted : CompressionError.Corrupt;
  }

  return move(stream);
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

pub static method(CompressionStream) DecompressAll(
  format: CompressionFormat, input: ref ByteBuffer, max_output: uint64, max_members: int32
) -> Result<ByteBuffer, CompressionError> {
  if max_members <= 0 {
    return CompressionError.InvalidArgument;
  }
  if input.Len() == 0 {
    return CompressionError.Truncated;
  }

  var output = ByteBuffer.New();
  var offset: int32 = 0;
  var members: int32 = 0;
  while offset < input.Len() {
    if members == max_members {
      return CompressionError.LimitExceeded;
    }

    var opened = CompressionStream.Decode(format, max_output - (output.Len() as uint64));
    if opened.IsErr() {
      return opened.get_if<CompressionError>() as CompressionError;
    }
    var decoder = move(opened.get_if<CompressionStream>() as CompressionStream);
    let read = decoder.CollectMember(input, offset, output);
    if read.IsErr() {
      return read.get_if<CompressionError>() as CompressionError;
    }

    offset = read.get_if<int32>() as int32;
    members += 1;
  }

  return output;
}

// Keep output private until the provider has consumed exactly one complete stream.
method(CompressionStream) Collect(input: ref ByteBuffer) -> Result<ByteBuffer, CompressionError> {
  var output = ByteBuffer.New();
  let end = self.CollectMember(input, 0, output);
  if end.IsErr() {
    return end.get_if<CompressionError>() as CompressionError;
  }
  if (end.get_if<int32>() as int32) != input.Len() {
    return CompressionError.TrailingData;
  }

  return output;
}

method(CompressionStream) CollectMember(
  input: ref ByteBuffer, start: int32, output: ref mut ByteBuffer
) -> Result<int32, CompressionError> {
  var block: <uint8>[16384] = <uint8>[16384]{};
  let buffer = MutableByteView{data: &mut block[0], length: kCompressionBlock as uintptr};
  var offset = start;
  while true {
    let step = self.PushInto(input, offset, input.Len() - offset, buffer, true);
    if step.IsErr() {
      return step.get_if<CompressionError>() as CompressionError;
    }

    let progress = step.get_if<CompressionTransfer>() as CompressionTransfer;
    offset += progress.consumed;
    if output.Write(&block[0], progress.produced as intptr).IsErr() {
      return CompressionError.ResourceExhausted;
    }
    if progress.complete {
      return offset;
    }
    if progress.consumed == 0 && progress.produced == 0 {
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
  let flushing = self.flushing;
  self.raw = nil;

  return CompressionStream{raw: raw, decoding: decoding, remaining: remaining, ending: ending, flushing: flushing};
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

pub method(CompressionStream) Flush() -> Result<CompressionFlush, CompressionError> {
  if self.raw == nil {
    return CompressionError.Closed;
  }
  if self.decoding || self.ending {
    return CompressionError.InvalidArgument;
  }

  var block: <uint8>[16384] = <uint8>[16384]{};
  var consumed: int32 = 0;
  var produced: int32 = 0;
  let status = nyra_compress_step(
    self.raw, nil, 0, &mut block[0], kCompressionBlock, kCompressionFlush, &mut consumed, &mut produced
  );
  if status > 1 {
    self.Close();
    return status == 3 ? CompressionError.ResourceExhausted : CompressionError.Corrupt;
  }

  var output = ByteBuffer.New();
  if output.Write(&block[0], produced as intptr).IsErr() {
    self.Close();
    return CompressionError.ResourceExhausted;
  }

  self.flushing = status == 0;
  return CompressionFlush{output: output, drained: !self.flushing};
}

pub method(CompressionStream) PushRange(
  input: ref ByteBuffer, offset: int32, length: int32, end_of_input: bool
) -> Result<CompressionProgress, CompressionError> {
  var block: <uint8>[16384] = <uint8>[16384]{};
  let buffer = MutableByteView{data: &mut block[0], length: kCompressionBlock as uintptr};
  let step = self.PushInto(input, offset, length, buffer, end_of_input);
  if step.IsErr() {
    return step.get_if<CompressionError>() as CompressionError;
  }

  let progress = step.get_if<CompressionTransfer>() as CompressionTransfer;
  var output = ByteBuffer.New();
  if output.Write(&block[0], progress.produced as intptr).IsErr() {
    self.Close();
    return CompressionError.ResourceExhausted;
  }

  return CompressionProgress{consumed: progress.consumed, output: output, complete: progress.complete};
}

pub method(CompressionStream) PushInto(
  input: ref ByteBuffer, offset: int32, length: int32, output: MutableByteView, end_of_input: bool
) -> Result<CompressionTransfer, CompressionError> {
  if self.raw == nil {
    return CompressionError.Closed;
  }
  if offset < 0 || offset > input.Len() || length < 0 || length > input.Len() - offset {
    return CompressionError.InvalidArgument;
  }

  let address = (input.Data() as intptr) + (offset as intptr);
  return self.PushBytes(ByteView{data: address as *const uint8, length: length as uintptr}, output, end_of_input);
}

pub method(CompressionStream) PushBytes(
  input: ByteView, output: MutableByteView, end_of_input: bool
) -> Result<CompressionTransfer, CompressionError> {
  if self.raw == nil {
    return CompressionError.Closed;
  }
  if self.flushing || (self.ending && !end_of_input) || input.length > 2147483647up ||
      !input.IsValid() || output.length == 0 || !output.IsValid() {
    return CompressionError.InvalidArgument;
  }

  self.ending = end_of_input;
  var consumed: int32 = 0;
  var produced: int32 = 0;
  var capacity = output.length < 2147483647up ? output.length as int32 : 2147483647;
  if self.decoding && self.remaining < (capacity as uint64) {
    // One probe byte distinguishes a trailer at the exact limit from more decoded data.
    capacity = (self.remaining as int32) + 1;
  }

  let finish: int32 = end_of_input ? 1 : 0;
  let status = nyra_compress_step(
    self.raw, input.data, input.length as int32, output.data, capacity,
    finish, &mut consumed, &mut produced
  );
  if status > 1 {
    self.Close();
    if status == 4 {
      return CompressionError.LimitExceeded;
    }
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

  if status == 1 {
    self.Close();
  }

  return CompressionTransfer{consumed: consumed, produced: produced, complete: status == 1};
}
