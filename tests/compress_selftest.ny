// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "compress.ny";

func run_codec(encoder: ref mut CompressionStream, bytes: ref ByteBuffer) -> Result<ByteBuffer, CompressionError> {
  var offset: int32 = 0;
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
  let encoded = run_codec(encoder, bytes);
  if AssertTrue(encoded.IsOk()) != 0 {
    return;
  }
  let wire = encoded.get_if<ByteBuffer>() as ByteBuffer;

  var decode = CompressionStream.Decode(format, bytes.Len() as uint64);
  var decoder = move(decode.get_if<CompressionStream>() as CompressionStream);
  let decoded = run_codec(decoder, wire);
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
  let rejected = run_codec(limited, wire);
  AssertTrue(rejected.IsErr() && (rejected.get_if<CompressionError>() as CompressionError) == CompressionError.LimitExceeded);

  var shortened = ByteBuffer.New();
  shortened.Write(wire.Data(), (wire.Len() - 1) as intptr);
  var truncated = CompressionStream.Decode(format, bytes.Len() as uint64);
  var partial = move(truncated.get_if<CompressionStream>() as CompressionStream);
  let failure = run_codec(partial, shortened);
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
