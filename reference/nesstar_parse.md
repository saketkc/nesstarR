# Parse a NESSTAR binary container

Reads the file into memory and parses the binary layout (resource index,
dataset descriptors, variable directories).

## Usage

``` r
nesstar_parse(path)
```

## Arguments

- path:

  Path to a `.Nesstar` file.

## Value

A `nesstar_binary` list (S3 class).
