// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "compress.ny";

func run_codec(
  encoder: ref mut CompressionStream, bytes: ref ByteBuffer, start: int32
) -> Result<ByteBuffer, CompressionError> {
  var offset = start;
  var output = ByteBuffer.New();
  while true {
    let result = encoder.Push(bytes, offset, true);
    if result.IsErr() {
      return result.get_if<CompressionError>() as CompressionError;
    }

    let block = result.get_if<CompressionProgress>() as CompressionProgress;
    if output.Write(block.output.Data(), block.output.Len() as intptr).IsErr() {
      return CompressionError.ResourceExhausted;
    }
    offset += block.consumed;
    if block.complete {
      AssertEqI32(offset, bytes.Len());
      return output;
    }
  }

  return CompressionError.Corrupt;
}

func check_codec(format: CompressionFormat) -> void {
  var bytes = ByteBuffer.New();
  var i: int32 = 0;
  while i < 4096 {
    bytes.WriteString("streaming gzip and zstd\n");
    i += 1;
  }

  var created = CompressionStream.Encode(format);
  if AssertTrue(created.IsOk()) != 0 {
    return;
  }
  var encoder = move(created.get_if<CompressionStream>() as CompressionStream);
  let invalid = encoder.PushRange(bytes, 1, bytes.Len(), true);
  AssertTrue(invalid.IsErr() && (invalid.get_if<CompressionError>() as CompressionError) == CompressionError.InvalidArgument);
  let prefix = encoder.PushRange(bytes, 0, 3, false);
  if AssertTrue(prefix.IsOk()) != 0 {
    return;
  }
  let first = prefix.get_if<CompressionProgress>() as CompressionProgress;
  AssertEqI32(first.consumed, 3);
  let encoded = run_codec(encoder, bytes, first.consumed);
  if AssertTrue(encoded.IsOk()) != 0 {
    return;
  }
  var wire = ByteBuffer.New();
  let last = encoded.get_if<ByteBuffer>() as ByteBuffer;
  wire.Write(first.output.Data(), first.output.Len() as intptr);
  wire.Write(last.Data(), last.Len() as intptr);

  var decode = CompressionStream.Decode(format, bytes.Len() as uint64);
  var decoder = move(decode.get_if<CompressionStream>() as CompressionStream);
  let decoded = run_codec(decoder, wire, 0);
  if AssertTrue(decoded.IsOk()) != 0 {
    return;
  }
  let actual = decoded.get_if<ByteBuffer>() as ByteBuffer;
  AssertEqI32(actual.Len(), bytes.Len());
  let source = string.ViewFrom(bytes.Data() as *const int8, bytes.Len());
  let dest = string.ViewFrom(actual.Data() as *const int8, actual.Len());
  AssertEqString(source, dest);

  var capped = CompressionStream.Decode(format, (bytes.Len() - 1) as uint64);
  var limited = move(capped.get_if<CompressionStream>() as CompressionStream);
  let rejected = run_codec(limited, wire, 0);
  AssertTrue(rejected.IsErr() && (rejected.get_if<CompressionError>() as CompressionError) == CompressionError.LimitExceeded);

  var shortened = ByteBuffer.New();
  shortened.Write(wire.Data(), (wire.Len() - 1) as intptr);
  var truncated = CompressionStream.Decode(format, bytes.Len() as uint64);
  var partial = move(truncated.get_if<CompressionStream>() as CompressionStream);
  let failure = run_codec(partial, shortened, 0);
  AssertTrue(failure.IsErr() && (failure.get_if<CompressionError>() as CompressionError) == CompressionError.Truncated);
}

@test
func test_gzip_stream_and_limits() {
  check_codec(CompressionFormat.Gzip);
}

@test
func test_zstd_stream_and_limits() {
  check_codec(CompressionFormat.Zstandard);
}

func check_whole_buffer(format: CompressionFormat) -> void {
  var input = ByteBuffer.New();
  input.WriteString("whole buffer");
  let encoded = CompressionStream.Compress(format, input);
  if AssertTrue(encoded.IsOk()) != 0 {
    return;
  }

  var wire = encoded.get_if<ByteBuffer>() as ByteBuffer;
  let decoded = CompressionStream.Decompress(format, wire, 12u64);
  if AssertTrue(decoded.IsOk()) != 0 {
    return;
  }

  let result = decoded.get_if<ByteBuffer>() as ByteBuffer;
  AssertEqString(string.ViewFrom(result.Data() as *const int8, result.Len()), "whole buffer");
  let limited = CompressionStream.Decompress(format, wire, 11u64);
  AssertTrue(limited.IsErr() && (limited.get_if<CompressionError>() as CompressionError) == CompressionError.LimitExceeded);
  wire.WriteString("extra");
  let trailing = CompressionStream.Decompress(format, wire, 12u64);
  AssertTrue(trailing.IsErr() && (trailing.get_if<CompressionError>() as CompressionError) == CompressionError.TrailingData);

  let empty = CompressionStream.Compress(format, ByteBuffer.New());
  if AssertTrue(empty.IsOk()) != 0 {
    return;
  }
  let decoded_empty = CompressionStream.Decompress(format, empty.get_if<ByteBuffer>() as ByteBuffer, 0u64);
  AssertTrue(decoded_empty.IsOk() && (decoded_empty.get_if<ByteBuffer>() as ByteBuffer).Len() == 0);
}

@test
func test_gzip_and_zstd_whole_buffers() {
  check_whole_buffer(CompressionFormat.Gzip);
  check_whole_buffer(CompressionFormat.Zstandard);
}
