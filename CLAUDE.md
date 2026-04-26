# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## Project

**nesstarR** is an R package that reads and parses NESSTAR binary
containers distributed by statistical agencies (e.g., MOSPI India for
census/survey data). It decodes compact binary formats into R data
frames and exports them to CSV.

## Commands

``` bash
# Load package (compiles C code)
Rscript -e "devtools::load_all()"

# Run all tests
Rscript -e "testthat::test_dir('tests/testthat')"

# Run a single test file
Rscript -e "testthat::test_file('tests/testthat/test-nesstar.R')"

# Generate documentation (roxygen2)
Rscript -e "roxygen2::roxygenise()"

# Full CRAN-style check
R CMD check .

# Install from source
R CMD INSTALL .
```

> **Note:** `tests/testthat/` is currently empty. Tests require actual
> `.Nesstar` binary files as fixtures; none are committed to the
> repository.

## Architecture

### Data Flow

    .Nesstar binary file
      → nesstar_parse()          [R: R/nesstar.R]
      → .Call("nesstar_parse_binary")
      → C parser                 [C: src/nesstar.c]
      → nesstar_binary S3 object

From the `nesstar_binary` object: - `nesstar_datasets(x)`: list datasets
with row/column counts - `nesstar_variables(x, n)`: describe variables
in dataset n - `nesstar_metadata(x)`: decode Huffman-compressed XML
labels - `nesstar_read_dataset(x, n, columns=NULL)`: read data into
data.frame - `nesstar_export(x, output_dir, ...)`: export to CSV.gz
(chunked, default 50k rows)

### Key Modules

**`R/nesstar.R`**: High-level R API and main entry point. The
[`nesstar_parse()`](https://saketkc.github.io/nesstarR/reference/nesstar_parse.md)
function reads the binary file and returns the S3 object. Chunked export
logic lives here.

**`R/metadata.R`**: Huffman-compressed XML metadata extraction.
Byte-order-aware integer reading (`.u32le`, `.u32be`). Metadata decoding
returns `NULL` with a warning for older formats without XML blocks.

**`src/nesstar.c`**: Three distinct responsibilities: 1. **Container
parsing** (`nesstar_parse_binary`): Detects byte order at offset 0x25,
parses resource index (ID→offset map), extracts dataset descriptors and
variable directories. 2. **Huffman decompression**
(`nesstar_decode_huffman`): Min-heap tree construction, bit-by-bit
traversal to decode XML metadata blocks. 3. **Column decoding**
(`nesstar_decode_column`, `nesstar_decode_column_range`): Mode 1 =
fixed-width UTF-16LE strings; Mode 5 = numeric
(nibble/byte/uint16/24/32/40/float64). Row-range support enables chunked
reads.

### Binary Format Details

- Magic bytes: `"NESSTART"` (8 bytes)
- Default byte order: little-endian; falls back to big-endian
- Strings: UTF-16LE in file, converted to UTF-8 for R
- Numeric formats: 4-bit nibble through IEEE 754 float64
- Resource index: maps record IDs to file offsets/lengths

### Reference

Full binary format documentation (header layout, resource index record
layout, variable directory fields, Huffman block structure, observed
file sizes) is in
[`NESSTAR_FORMAT.md`](https://saketkc.github.io/nesstarR/NESSTAR_FORMAT.md).

### Known Format Quirks

**5-byte (u40 LE) offsets for files \> 4 GB**: The resource index
location (stored at header offset 0x25) and per-record `target_offset`
fields in the resource index are **40-bit little-endian**, not 32-bit.
Byte 0x29 in the header is the high byte of the index offset; byte `+8`
in each 15-byte resource record is the high byte of its `target_offset`.
Files ≤ 4 GB have these bytes as `0x00`, so 32-bit reads work
accidentally. Fixed in `src/nesstar.c` (`parse_resource_index`,
`detect_byte_order`, `ResRecord.target_offset`).

**mode_code 0 variables**: Some older NSS files contain variable
directory entries with `mode_code = 0` (neither string/1 nor numeric/5).
These are treated as all-NA numeric columns. Guard added in
`R/nesstar.R` (`.decode_columns`, `.decode_columns_range`) before the C
call.

**R-side metadata index reads only 32-bit offsets**:
`R/metadata.R::.build_resource_index` uses `.u32le` / `.u32be`, so it
reads 4-byte offsets. The C parser correctly reads 5-byte (u40) offsets.
This means
[`nesstar_metadata()`](https://saketkc.github.io/nesstarR/reference/nesstar_metadata.md)
will break on files \> 4 GB (e.g. the 68th-round Type 1 file). The fix
is to add the 5th byte from `raw[idx_off + 5]` as a high byte, mirroring
the C logic.

### Other Files

**`stata/`**: Contains reference STATA zip archives from MOSPI
(`DDI-IND-MOSPI-NSSO-HCES22-23_STATA.zip`, `Nss68_STATA_2012.zip`).
These are not part of the R package; they serve as reference datasets
for validating parser output.

### Dependencies

No external R packages; only base R and `tools` (built-in). C code is
compiled on first install/load via `src/Makevars` (`-Wall -Wextra -O2`).
