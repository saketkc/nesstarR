# NESSTAR Binary Format

This documents the `.Nesstar` binary container format as
reverse-engineered from MOSPI India HCES survey files. It is a
proprietary format produced by the NESSTAR Publisher software (now
discontinued).

------------------------------------------------------------------------

## File Structure Overview

    [Header - 0x57 bytes]
    [Data blocks - variable-length, one per variable per dataset]
    [Huffman-compressed XML metadata blocks - optional]
    [Resource index - trailing, variable length]

All integers are **little-endian** in every file seen to date (MOSPI
HCES rounds 57–68). A big-endian fallback is detected heuristically but
has not been observed in practice.

------------------------------------------------------------------------

## Header (bytes 0x00–0x56)

| Offset | Size  | Field                    | Notes                                                                                                                             |
|--------|-------|--------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
| 0x00   | 8     | Magic                    | ASCII `NESSTART`                                                                                                                  |
| 0x08   | 4     | Unknown                  | Possibly a version or checksum                                                                                                    |
| 0x0C   | 4+    | Unknown                  | Padding / reserved                                                                                                                |
| 0x25   | **5** | `resource_index_offset`  | **40-bit LE** (u40). Low 4 bytes at 0x25, high byte at 0x29. Files ≤ 4 GB have byte 0x29 = 0; files \> 4 GB require the 5th byte. |
| 0x2B   | 1     | `dataset_count`          | Number of datasets in the container                                                                                               |
| 0x2D   | 2     | `descriptor_record_size` | Byte size of each dataset descriptor entry (observed: 26)                                                                         |
| 0x2F   | 4     | `base_record_id`         | Resource ID of the dataset descriptor table                                                                                       |

------------------------------------------------------------------------

## Resource Index

Located at `resource_index_offset` (from header), **at the end of the
file** (“trailing index”).

    [u32 LE]  count          - number of records
    [count × 15-byte records]

Each 15-byte record:

| Offset in record | Size  | Field           | Notes                                                                                         |
|------------------|-------|-----------------|-----------------------------------------------------------------------------------------------|
| +0               | 4     | `record_id`     | Unique ID; used as a foreign key throughout the file                                          |
| +4               | **5** | `target_offset` | **40-bit LE** (u40). Low 4 bytes at +4, high byte at +8. Byte at +8 is 0 for offsets \< 4 GB. |
| +9               | 1     | Unknown         | Gap / alignment byte                                                                          |
| +10              | 4     | `length`        | Byte length of the referenced block                                                           |

`MAX_RESOURCES` observed: ~1,300 for a 4.65 GB file (68th round, Type
1).

------------------------------------------------------------------------

## Dataset Descriptor Table

Located at `target_offset` of the record with
`record_id == base_record_id`.  
Contains `dataset_count` entries, each `descriptor_record_size` bytes.

Each entry:

| Offset | Size | Field                                           |
|--------|------|-------------------------------------------------|
| +0     | 4    | `dataset_number`                                |
| +4     | 4    | `variable_count`                                |
| +8     | 4    | `row_count`                                     |
| +12    | 4    | `row_count` (duplicate, validated as equal)     |
| +16    | 4    | `file_description_record_id`                    |
| +20    | 2    | `variable_directory_entry_size` (observed: 160) |
| +22    | 4    | `variable_directory_record_id`                  |

------------------------------------------------------------------------

## Variable Directory

Located at `target_offset` of the record with
`record_id == variable_directory_record_id`.  
Contains `variable_count` entries, each `variable_directory_entry_size`
(160) bytes.

Key fields within each 160-byte entry:

| Offset | Size | Field                  | Notes                                           |
|--------|------|------------------------|-------------------------------------------------|
| +5     | 1    | `value_format_code`    | Numeric encoding format (see below)             |
| +6     | 8    | `value_offset_i64`     | i64 LE additive bias for numeric values         |
| +15    | 4    | `variable_id`          | Resource ID → data block in resource index      |
| +63    | 64   | `name`                 | UTF-16LE, null-terminated, up to 32 characters  |
| +127   | 4    | `label_resource_id`    | Resource ID of Huffman-compressed label XML     |
| +131   | 2    | `category_resource_id` | Resource ID of category-code XML                |
| +149   | 1    | `width_value`          | For strings: byte width per row                 |
| +155   | 4    | `object_id`            |                                                 |
| +159   | 1    | `mode_code`            | Data type: 1 = string, 5 = numeric, 0 = no-data |

------------------------------------------------------------------------

## Data Blocks

Each variable’s data occupies a contiguous block at `target_offset` of
the record with `record_id == variable_id`.

### Mode 1: Strings

Fixed-width, `width_value` bytes per row, **not** UTF-16LE (plain bytes,
effectively ASCII/Latin-1). Row `i` occupies
`[i * width, i * width + width)`.

### Mode 5: Numerics

Encoded value = `stored_raw + value_offset_i64`.

| `value_format_code` | Format                | Bytes/row | Missing sentinel               |
|---------------------|-----------------------|-----------|--------------------------------|
| 2                   | 4-bit nibble (packed) | 0.5       | `0x0F`                         |
| 3                   | uint8                 | 1         | `0xFF`                         |
| 4                   | uint16 LE             | 2         | `0xFFFF`                       |
| 5                   | uint24 LE             | 3         | `0xFFFFFF`                     |
| 6                   | uint32 LE             | 4         | `0xFFFFFFFF`                   |
| 7                   | uint40 LE             | 5         | `0xFFFFFFFFFF`                 |
| 10                  | IEEE 754 float64 LE   | 8         | `0x7FEFFFFFFFFFFFFF` (DBL_MAX) |

### Mode 0: No data

Variable directory entry is present but the resource index has no record
for `variable_id` (i.e., `data_length == 0`). Decoded as all-NA.

------------------------------------------------------------------------

## Huffman-Compressed XML Metadata

Variable labels and category codes are stored as Huffman-compressed XML
blocks. Each block:

    [optional: 1 byte dataset-index]
    [1 byte]  symbol_count  (1–256)
    [1 byte]  reserved
    [1 byte]  reserved
    [symbol_count × 5 bytes]  symbol table: (symbol_byte u8, freq u32le)
    [4 bytes]  output_length u32le  (== sum of all frequencies)
    [bit stream, LSB-first]

The tree is built as a standard min-heap Huffman tree. Single-symbol
alphabets are a degenerate case (all bits → 0 → left child repeatedly).

Older NSS-format files (rounds 57–63, delivered as CSV) do not embed
metadata XML;
[`nesstar_metadata()`](https://saketkc.github.io/nesstarR/reference/nesstar_metadata.md)
returns `NULL` for these.

------------------------------------------------------------------------

## Observed File Sizes and Quirks

| Round       | File                                        | Size             | Notes                                           |
|-------------|---------------------------------------------|------------------|-------------------------------------------------|
| NSS 66th T1 | `nss66_consumer_expenditure_type_1.Nesstar` | 1.39 GB          | 9 datasets                                      |
| NSS 66th T2 | `nss66_consumer_expenditure_type_2.Nesstar` | found inside rar | 9 datasets                                      |
| NSS 68th T2 | `nss68_consumer_expenditure_type2.Nesstar`  | 1.48 GB          | 11 datasets; contains mode_code=0 variables     |
| NSS 68th T1 | `nss68_consumer_expenditure_type_1.Nesstar` | **4.65 GB**      | 11 datasets; **requires 5-byte offset parsing** |

The 68th T1 file is the only one observed to exceed 4 GB, triggering the
40-bit offset requirement.
