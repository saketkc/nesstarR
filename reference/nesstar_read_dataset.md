# Read one dataset into an R data frame

Numeric columns (mode 5) become `numeric`; string columns (mode 1)
become `character`. Missing values are `NA`.

## Usage

``` r
nesstar_read_dataset(x, dataset_number, columns = NULL)
```

## Arguments

- x:

  A `nesstar_binary` object.

- dataset_number:

  Integer dataset number.

- columns:

  Optional character vector of column names to read. When `NULL`
  (default) all columns are returned.

## Value

A `data.frame`.
