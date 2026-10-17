# nesstarR <img src="man/figures/logo.png" align="right" height="139" alt="nesstarR logo" />

nesstarR reads `.Nesstar` binary files into R data frames and writes them to CSV files.

`.Nesstar` is the file format of Nesstar Publisher. Nesstar Publisher is survey documentation software from the [International Household Survey Network (IHSN)](https://www.ihsn.org/node/557). Statistical agencies, for example the [Ministry of Statistics and Programme Implementation (MoSPI), India](https://mospi.gov.in/), publish survey microdata in this format. nesstarR does not need Nesstar software.

## Installation

```r
install.packages("nesstarR")

# Development version
devtools::install_github("saketkc/nesstarR")
```

## Quick start

```r
library(nesstarR)

x <- nesstar_parse("path/to/file.Nesstar")
x
#> <nesstar_binary>
#>  File      : file.Nesstar 
#>  Datasets  : 3

nesstar_datasets(x)
#>   dataset_number row_count variable_count
#> 1              1    500000             42
#> 2              2    120000             18
#> 3              3     80000             31

nesstar_variables(x, dataset_number = 1)

# Read all columns, or only the columns that you specify
df <- nesstar_read_dataset(x, dataset_number = 1)
df_subset <- nesstar_read_dataset(x, dataset_number = 1, columns = c("AGE", "DISTRICT", "INCOME"))
```

## Metadata

A `.Nesstar` file contains XML blocks with variable labels and category codes. Huffman coding compresses these blocks.

```r
meta <- nesstar_metadata(x)

# one entry per dataset
ds <- meta$datasets[[1]]
ds$file_name       # original survey file name
ds$variables[[1]]  # list(name, label, categories)
```

Some older NSS files do not contain these XML blocks. For these files, `nesstar_metadata()` gives a warning and returns `NULL`.

## Export to CSV

`nesstar_export()` writes each dataset to a different CSV file. By default, it reads 50,000 rows at a time. This limits the memory use for large files.

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

## Format notes

A `.Nesstar` file has two column types:

- Mode 1 (string): fixed-width UTF-16LE fields. nesstarR returns them as `character`.
- Mode 5 (numeric): packed formats, from 4-bit values to IEEE 754 `float64`. nesstarR returns them as `numeric`. Missing values become `NA`.

The parser finds the byte order of the file. It tries little-endian first and then big-endian. It converts all strings to UTF-8.
