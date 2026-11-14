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

@test
func test_gzip_and_zstd_flush_without_ending() {
  AssertTrue(CompressionStream.EncodeLevel(CompressionFormat.Gzip, 10).IsErr());
  AssertTrue(CompressionStream.EncodeLevel(CompressionFormat.Zstandard, 0).IsErr());
  check_flush(CompressionFormat.Gzip, 0);
  check_flush(CompressionFormat.Zstandard, 1);
}

func check_flush(format: CompressionFormat, level: int32) -> void {
  var opened = CompressionStream.EncodeLevel(format, level);
  if AssertTrue(opened.IsOk()) != 0 {
    return;
  }

  var encoder = move(opened.get_if<CompressionStream>() as CompressionStream);
  var input = ByteBuffer.New();
  input.WriteString("first");
  let pushed = encoder.Push(input, 0, false);
  if AssertTrue(pushed.IsOk()) != 0 {
    return;
  }
  let progress = pushed.get_if<CompressionProgress>() as CompressionProgress;
  AssertEqI32(progress.consumed, 5);
  var wire = ByteBuffer.New();
  wire.Write(progress.output.Data(), progress.output.Len() as intptr);
  let flushed = encoder.Flush();
  if AssertTrue(flushed.IsOk()) != 0 {
    return;
  }
  let chunk = flushed.get_if<CompressionFlush>() as CompressionFlush;
  AssertTrue(chunk.drained);
  wire.Write(chunk.output.Data(), chunk.output.Len() as intptr);

  var decoder_result = CompressionStream.Decode(format, 11u64);
  var decoder = move(decoder_result.get_if<CompressionStream>() as CompressionStream);
  let early = decoder.Push(wire, 0, false);
  if AssertTrue(early.IsOk()) != 0 {
    return;
  }
  let decoded = early.get_if<CompressionProgress>() as CompressionProgress;
  AssertTrue(!decoded.complete);
  AssertEqString(string.ViewFrom(decoded.output.Data() as *const int8, decoded.output.Len()), "first");

  input.WriteString("second");
  let tail = run_codec(encoder, input, 5);
  if AssertTrue(tail.IsOk()) != 0 {
    return;
  }
  let final_wire = tail.get_if<ByteBuffer>() as ByteBuffer;
  wire.Write(final_wire.Data(), final_wire.Len() as intptr);
  let all = CompressionStream.Decompress(format, wire, 11u64);
  if AssertTrue(all.IsOk()) != 0 {
    return;
  }
  let actual = all.get_if<ByteBuffer>() as ByteBuffer;
  AssertEqString(string.ViewFrom(actual.Data() as *const int8, actual.Len()), "firstsecond");
}

@test
func test_gzip_and_zstd_concatenated_members() {
  check_concatenated(CompressionFormat.Gzip);
  check_concatenated(CompressionFormat.Zstandard);
}

func check_concatenated(format: CompressionFormat) -> void {
  var input = ByteBuffer.New();
  let empty = CompressionStream.Compress(format, input);
  input.WriteString("data");
  let full = CompressionStream.Compress(format, input);
  if AssertTrue(empty.IsOk() && full.IsOk()) != 0 {
    return;
  }

  let a = empty.get_if<ByteBuffer>() as ByteBuffer;
  let b = full.get_if<ByteBuffer>() as ByteBuffer;
  var wire = ByteBuffer.New();
  wire.Write(a.Data(), a.Len() as intptr);
  wire.Write(b.Data(), b.Len() as intptr);
  wire.Write(a.Data(), a.Len() as intptr);
  let decoded = CompressionStream.DecompressAll(format, wire, 4u64, 3);
  if AssertTrue(decoded.IsOk()) != 0 {
    return;
  }
  let output = decoded.get_if<ByteBuffer>() as ByteBuffer;
  AssertEqString(string.ViewFrom(output.Data() as *const int8, output.Len()), "data");
  let members = CompressionStream.DecompressAll(format, wire, 4u64, 2);
  let output_limit = CompressionStream.DecompressAll(format, wire, 3u64, 3);
  AssertTrue(members.IsErr() && (members.get_if<CompressionError>() as CompressionError) == CompressionError.LimitExceeded);
  AssertTrue(output_limit.IsErr() && (output_limit.get_if<CompressionError>() as CompressionError) == CompressionError.LimitExceeded);
  AssertTrue(CompressionStream.Decompress(format, wire, 4u64).IsErr());

  var short = ByteBuffer.New();
  short.Write(wire.Data(), (wire.Len() - 1) as intptr);
  let truncated = CompressionStream.DecompressAll(format, short, 4u64, 3);
  AssertTrue(truncated.IsErr() && (truncated.get_if<CompressionError>() as CompressionError) == CompressionError.Truncated);
}
