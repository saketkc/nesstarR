# Export all datasets to CSV files

Writes each dataset to a CSV file named after the container and dataset
number.

## Usage

``` r
nesstar_export(
  x,
  output_dir,
  datasets = NULL,
  compress = TRUE,
  chunk_size = 50000L
)
```

## Arguments

- x:

  A `nesstar_binary` object.

- output_dir:

  Directory to write files into. Created if it does not exist.

- datasets:

  Integer vector of dataset numbers to export. When `NULL` (default)
  every dataset is exported.

- compress:

  Logical; when `TRUE` (default) output files are gzip-compressed
  (`.csv.gz`).

- chunk_size:

  Number of rows to process per iteration (reduces peak memory use).

## Value

Invisibly, a character vector of output file paths.
