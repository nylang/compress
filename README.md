# Nyra compression

The hosted `compress` package encodes and decodes gzip and Zstandard
streams. Compile `private/native/codec.c` with zlib and Zstandard headers
and link the object with both libraries.

Create a `CompressionStream` with `Encode` or `Decode`. The decoder
requires an explicit total decoded byte limit. Call `Push` with the
current input block and its consumed offset, collect the owned output
block, and advance by the exact consumed count. Supply `end_of_input` for
the last block and subsequent drains. Use `PushRange` to process a single
subrange of a reused buffer. Invalid ranges leave the cursor usable.
Use `PushInto` with a nonempty `MutableByteView` to write directly into
a reusable output buffer. Advance by the returned consumed count and use
only the produced prefix. The input and output ranges must be disjoint.
A completed decoder stops at one
gzip member or Zstandard frame. Use the consumed count to hand trailing
bytes to another cursor if your format permits multiple members. A
truncated input or exhausted decoded-byte budget retires the cursor.

For inputs that already fit in memory, `CompressionStream.Compress`
and `CompressionStream.Decompress` return a complete owned buffer.
Decompression requires an explicit output budget and returns `TrailingData`
if anything follows the first member or frame.
Use `DecompressAll` for concatenated members or frames of one format.
The output limit applies across the whole input, and the member limit
includes empty members.

`EncodeLevel` selects gzip levels 0 through 9 or Zstandard levels 1 through 22.
After the encoder has consumed the supplied input, call `Flush` until it
reports `drained`. Append every returned output block to the same stream.
Flushing makes the accepted data available to a decoder while leaving the
member or frame open for further writes.

`DecodeZstandard(max_output, window_log)` lets callers cap the frame's
advertised history window separately from its total decoded size. Values
10 through 27 select powers of two in bytes. Codec overhead is additional.

`EncodeZstandardDictionary` and `DecodeZstandardDictionary` copy a raw
or trained dictionary into the provider. Supply the same dictionary to
both ends. Dictionary encoding enables the frame checksum. Decoding
enforces the independent output and history-window limits.
