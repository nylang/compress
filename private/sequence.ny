// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Coordinates member boundaries and aggregate budgets over a single codec cursor. */
module CompressionSequences;
import "stdlib:stdlib.ny";
import "interface/compress.ni";
import "private/codec.ny";

/** @brief Owns one active decoder and counters for the complete input. */
pub struct CompressionSequence {
  stream: CompressionStream;
  format: CompressionFormat;
  remaining: uint64;
  max_members: int32;
  members: int32;
  active: bool;
  ending: bool;
  closed: bool;
}

pub method(CompressionSequence) operator move() -> CompressionSequence {
  let closed = self.closed;
  self.closed = true;

  return CompressionSequence{
    stream: move(self.stream), format: self.format, remaining: self.remaining, max_members: self.max_members,
    members: self.members, active: self.active, ending: self.ending, closed: closed
  };
}

pub static method(CompressionSequence) New(
  format: CompressionFormat, max_output: uint64, max_members: int32
) -> Result<CompressionSequence, CompressionError> {
  if max_members <= 0 {
    return CompressionError.InvalidArgument;
  }

  return CompressionSequence{format: format, remaining: max_output, max_members: max_members};
}

pub method(CompressionSequence) PushBytes(
  input: ByteView, output: MutableByteView, end_of_input: bool
) -> Result<CompressionTransfer, CompressionError> {
  if self.closed || self.max_members == 0 {
    return CompressionError.Closed;
  }
  if !input.IsValid() || input.length > 2147483647up || !output.IsValid() || output.length == 0 ||
      (self.ending && !end_of_input) {
    return CompressionError.InvalidArgument;
  }

  self.ending = end_of_input;
  if !self.active {
    if input.length == 0 {
      self.closed = end_of_input;
      if end_of_input && self.members == 0 {
        return CompressionError.Truncated;
      }
      return CompressionTransfer{complete: end_of_input};
    }
    if self.members == self.max_members {
      self.closed = true;
      return CompressionError.LimitExceeded;
    }

    var opened = CompressionStream.Decode(self.format, self.remaining);
    if opened.IsErr() {
      self.closed = true;
      return opened.get_if<CompressionError>() as CompressionError;
    }

    self.stream = move(opened.get_if<CompressionStream>() as CompressionStream);
    self.active = true;
  }

  let stepped = self.stream.PushBytes(input, output, end_of_input);
  if stepped.IsErr() {
    self.closed = true;
    return stepped.get_if<CompressionError>() as CompressionError;
  }

  let progress = stepped.get_if<CompressionTransfer>() as CompressionTransfer;
  self.remaining -= progress.produced as uint64;
  if progress.complete {
    self.active = false;
    self.members += 1;
    self.closed = end_of_input && (progress.consumed as uintptr) == input.length;
  }

  return CompressionTransfer{consumed: progress.consumed, produced: progress.produced, complete: self.closed};
}

pub static method(CompressionSequence) DecodeStream(
  format: CompressionFormat, source: ref mut Stream, destination: ref mut Stream,
  max_output: uint64, max_members: int32
) -> Result<Unit, CompressionError> {
  var opened = CompressionSequence.New(format, max_output, max_members);
  if opened.IsErr() {
    return opened.get_if<CompressionError>() as CompressionError;
  }

  var decoder = move(opened.get_if<CompressionSequence>() as CompressionSequence);
  var input: <uint8>[16384] = <uint8>[16384]{};
  var output: <uint8>[16384] = <uint8>[16384]{};
  let target = MutableByteView{data: &mut output[0], length: 16384up};
  var size: intptr = 0;
  var offset: intptr = 0;
  var eof = false;
  while true {
    if !eof && offset == size {
      let read = source.Read(&mut input[0], 16384ip);
      if read.IsErr() {
        return CompressionError.Io;
      }

      size = read.get_if<intptr>() as intptr;
      if size < 0ip || size > 16384ip {
        return CompressionError.Io;
      }
      offset = 0ip;
      eof = size == 0ip;
    }

    let address = (&input[0] as intptr) + offset;
    let view = ByteView{data: address as *const uint8, length: (size - offset) as uintptr};
    let stepped = decoder.PushBytes(view, target, eof);
    if stepped.IsErr() {
      return stepped.get_if<CompressionError>() as CompressionError;
    }

    let progress = stepped.get_if<CompressionTransfer>() as CompressionTransfer;
    var written: intptr = 0;
    while written < (progress.produced as intptr) {
      let remaining = (progress.produced as intptr) - written;
      let cursor = (&output[0] as intptr) + written;
      let sent = destination.Write(cursor as *const uint8, remaining);
      if sent.IsErr() {
        return CompressionError.Io;
      }

      let count = sent.get_if<intptr>() as intptr;
      if count <= 0ip || count > remaining {
        return CompressionError.Io;
      }
      written += count;
    }
    if progress.complete {
      return UnitValue();
    }
    if progress.consumed == 0 && progress.produced == 0 {
      return CompressionError.Corrupt;
    }
    offset += progress.consumed as intptr;
  }

  return CompressionError.Corrupt;
}
