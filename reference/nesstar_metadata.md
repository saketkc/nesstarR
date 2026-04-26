# Read embedded XML metadata from a NESSTAR container

Decodes the Huffman-compressed XML blocks embedded in the container to
recover dataset file names, variable labels, and categorical value
labels.

## Usage

``` r
nesstar_metadata(x)
```

## Arguments

- x:

  A `nesstar_binary` object from
  [`nesstar_parse`](https://saketkc.github.io/nesstarR/reference/nesstar_parse.md).

## Value

A named list:

- `datasets`:

  A list, one element per dataset, each containing `dataset_number`,
  `file_name`, and `variables` (a list of per-variable lists with
  `name`, `label`, and `categories`).

Returns `NULL` (with a warning) when metadata cannot be decoded.

## Details

If the embedded metadata blocks cannot be decoded (e.g. older NSS files
where record IDs differ) the function returns `NULL` with a warning
instead of stopping.
