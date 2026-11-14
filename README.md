# Nyra compression

The hosted `compress` package encodes and decodes gzip and Zstandard
streams. Compile `private/native/codec.c` with zlib and Zstandard headers
and link the object with both libraries.

Create a `CompressionStream` with `Encode` or `Decode`. The decoder
requires an explicit total decoded byte limit. Call `Push` with the
current input block and its consumed offset, collect the owned output
block, and advance by the exact consumed count. Supply `end_of_input` for
the last block and subsequent drains. A completed decoder stops at one
gzip member or Zstandard frame. Use the consumed count to hand trailing
bytes to another cursor if your format permits multiple members. A
truncated input or exhausted decoded-byte budget retires the cursor.
