# nesstarR

Reads `.Nesstar` binary containers from statistical agencies like [MOSPI India](https://mospi.gov.in/) into R data frames and exports them to CSV.

## Installation

```r
devtools::install_github("saketkc/nesstarR")
```

## Quick start

```r
library(nesstarR)

x <- nesstar_parse("path/to/file.Nesstar")
x
#> NESSTAR container: file.Nesstar
#> 3 dataset(s)

nesstar_datasets(x)
#>   dataset_number row_count variable_count
#> 1              1    500000             42
#> 2              2    120000             18
#> 3              3     80000             31

nesstar_variables(x, dataset_number = 1)

# Read a full dataset or just the columns you need
df <- nesstar_read_dataset(x, dataset_number = 1)
df_subset <- nesstar_read_dataset(x, dataset_number = 1, columns = c("AGE", "DISTRICT", "INCOME"))
```

## Metadata

NESSTAR files embed Huffman-compressed XML with variable labels and category codes:

```r
meta <- nesstar_metadata(x)

# one entry per dataset
ds <- meta$datasets[[1]]
ds$file_name       # original survey file name
ds$variables[[1]]  # list(name, label, categories)
```

Older NSS-format files lack XML blocks; `nesstar_metadata()` returns `NULL` with a warning for those.

## Exporting to CSV

`nesstar_export()` writes each dataset to its own CSV file. It reads 50,000 rows at a time by default, so large files don't blow up your memory:

```r
# All datasets, gzip-compressed (default)
nesstar_export(x, output_dir = "./data")
# Writes: data/file_ds1.csv.gz, data/file_ds2.csv.gz, ...

# Specific datasets, plain CSV, smaller chunks
nesstar_export(
  x,
  output_dir = "./data",
  datasets   = c(1, 2),
  compress   = FALSE,
  chunk_size = 10000L
)
```

The function returns the output file paths invisibly.

## Reference functions

| Function | What it does |
|---|---|
| `nesstar_parse(path)` | Parse a `.Nesstar` file; returns a `nesstar_binary` object |
| `nesstar_datasets(x)` | Data frame of dataset numbers, row counts, and variable counts |
| `nesstar_variables(x, dataset_number)` | Data frame of variable names, types, and binary layout |
| `nesstar_read_dataset(x, dataset_number, columns)` | Read one dataset into a data frame |
| `nesstar_metadata(x)` | Decode embedded XML labels and category codes |
| `nesstar_export(x, output_dir, ...)` | Export datasets to CSV or CSV.gz |

## Format notes

Two column types appear in NESSTAR containers:

- Mode 1 (strings): fixed-width UTF-16LE fields, returned as `character`
- Mode 5 (numerics): packed formats from 4-bit nibbles to IEEE 754 `float64`, returned as `numeric`; missing values become `NA`

The parser auto-detects byte order (little-endian by default, big-endian fallback) and converts all strings to UTF-8.

## License

MIT 
