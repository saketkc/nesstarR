# Reading NESSTAR survey data with nesstarR

[NSS rounds 64, 66, and
68](https://microdata.gov.in/NADA/index.php/catalog/?page=1&sort_order=desc&ps=15)
come as `.Nesstar` binaries inside `.rar` archives. Download them with
the sister package [mospiR](https://github.com/saketkc/mospiR), extract
with `unar`, and read with nesstarR. All examples below use NSS 68th
Round Type 2 (Consumer Expenditure Survey, July 2011 - June 2012); the
same steps apply to NSS 64 and 66.

## Prerequisites

``` r
remotes::install_github("saketkc/mospiR")
remotes::install_github("saketkc/nesstarR")
```

``` r
library(mospiR)
library(nesstarR)
```

## Download from the portal

[`mospiR::download_dataset()`](https://saketkc.github.io/mospiR/reference/download_dataset.html)
authenticates with the MoSPI NADA API and downloads the full archive for
one survey idno. The API key is read from `MOSPI_KEY` (set it in
`~/.Renviron`).

``` r
api_key  <- Sys.getenv("MOSPI_KEY")
data_dir <- file.path("data", "hces",
                      "DDI-IND-MOSPI-NSSO-68Rnd-Sch2.0-July2011-June2012")

download_dataset(
  "DDI-IND-MOSPI-NSSO-68Rnd-Sch2.0-July2011-June2012",
  data_dir,
  api_key
)
```

The download is a `.rar` archive, around 270 MB for NSS 68 T2.

## Extract the archive

`unar` (macOS/Linux) and `unrar` (Windows) both work. Either must be on
your `PATH`.

``` r
rar_file <- file.path(data_dir, "Nss68_1.0_Type2_new format.rar")
system2("unar", c("-o", dirname(rar_file), shQuote(rar_file)))
```

Extraction produces a folder containing:

- `survey0/data/nss68_consumer_expenditure_type2.Nesstar` (the binary
  data)
- `ddi.xml` (variable metadata in DDI format, not required by nesstarR)
- `Readme.pdf` / supporting documents

## Parse the Nesstar file

[`nesstar_parse()`](https://saketkc.github.io/nesstarR/reference/nesstar_parse.md)
reads the entire file into memory and decodes the binary header,
resource index, dataset descriptors, and variable directories. No row
data is loaded at this stage.

``` r
nb <- nesstar_parse(nesstar_path)
nb
#> <nesstar_binary>
#>  File      : nss68_consumer_expenditure_type2.Nesstar 
#>  Datasets  : 11
```

## Dataset structure

A single `.Nesstar` container holds multiple datasets, one per schedule
block (household, person, food, non-food, …).

``` r
nesstar_datasets(nb)
#>    dataset_number row_count variable_count
#> 1              47    101651             37
#> 2              48    101651             42
#> 3              49    101651             35
#> 4              50    464730             39
#> 5              51   5277850             32
#> 6              52   1493313             29
#> 7              53    370071             28
#> 8              54   2343672             28
#> 9              55   3436786             36
#> 10             56   3317537             28
#> 11             57    101647             41
```

The dataset with the largest row count is the food block: one row per
household × item combination (~4-5 million rows for NSS 68 T2).

``` r
ds_tbl <- nesstar_datasets(nb)
food_ds <- ds_tbl$dataset_number[which.max(ds_tbl$row_count)]
cat("Food block dataset number:", food_ds, "\n")
#> Food block dataset number: 51
cat("Rows:", ds_tbl$row_count[ds_tbl$dataset_number == food_ds], "\n")
#> Rows: 5277850
```

## Variable listing

``` r
vars <- nesstar_variables(nb, dataset_number = food_ds)
vars[, c("name", "mode_code", "value_format_code", "width_value")]
#>                           name mode_code value_format_code width_value
#> 1            Round_Centre_Code         1                 2           3
#> 2                FSU_Serial_No         1                 2           5
#> 3                        Round         1                 2           2
#> 4                       Sch_no         1                 2           3
#> 5                       Sample         1                 2           1
#> 6                       Sector         1                 2           1
#> 7                 State_region         1                 2           3
#> 8                     District         1                 2           2
#> 9                      Stratum         1                 2           2
#> 10              Sub_Stratum_No         1                 2           2
#> 11               Schedule_type         1                 2           1
#> 12                   Sub_Round         1                 2           1
#> 13                  Sub_Sample         1                 2           1
#> 14              FOD_Sub_region         1                 2           4
#> 15 Hamlet_Group_Sub_Stratum_no         1                 2           1
#> 16     Second_Stage_Stratum_No         1                 2           1
#> 17              Sample_hhld_no         1                 2           2
#> 18                       Level         1                 2           2
#> 19                   Item_Code         1                 2           3
#> 20       Home_Produce_Quantity         5                 5           7
#> 21          Home_Produce_Value         5                 4           5
#> 22  Total_Consumption_Quantity         5                 5           7
#> 23     Total_Consumption_Value         5                 5           5
#> 24                 Source_Code         1                 2           1
#> 25                         NSS         5                 3           2
#> 26                         NSC         5                 3           2
#> 27                         MLT         5                 6           8
#> 28                        HHID         1                 2           9
#> 29                  State_code         1                 2           2
#> 30               District_Code         1                 2           4
#> 31         Combined_Multiplier         5                10           9
#> 32        Subsample_multiplier         0                10           9
```

## Embedded labels and category codes

NESSTAR files from NSS 64 onwards embed Huffman-compressed XML blocks
with variable labels and category codes.

``` r
meta <- nesstar_metadata(nb)
#> Warning in nesstar_metadata(nb): Embedded metadata record ids 1 and 2 not
#> found; this file uses an older format. Labels are unavailable.
if (!is.null(meta)) {
  ds_meta <- meta$datasets[[which(
    vapply(meta$datasets, `[[`, integer(1), "dataset_number") == food_ds
  )]]
  cat("File name stored in container:", ds_meta$file_name, "\n\n")

  for (v in head(ds_meta$variables, 6)) {
    cat(sprintf("%-20s  label: %s\n", v$name, v$label))
    if (length(v$categories) > 0) {
      for (cat_entry in head(v$categories, 4)) {
        cat(sprintf("  %s = %s\n", cat_entry$value, cat_entry$label))
      }
    }
  }
} else {
  message("Metadata not available for this file (older NSS format).")
}
#> Metadata not available for this file (older NSS format).
```

## Read a dataset

[`nesstar_read_dataset()`](https://saketkc.github.io/nesstarR/reference/nesstar_read_dataset.md)
decodes all columns for the requested dataset. For the food block this
is the slow step (~10-30 s on a laptop): 4–5 million rows × ~20 columns,
decoded from the packed binary format.

Pass `columns` to load only what you need:

``` r
food <- nesstar_read_dataset(
  nb,
  dataset_number = food_ds,
  columns = c("HHID", "State_code", "District_Code", "Sector",
              "Combined_Multiplier", "Item_Code", "Total_Consumption_Value")
)
cat("Rows:", nrow(food), "| Columns:", ncol(food), "\n")
#> Rows: 5277850 | Columns: 7
head(food)
#>   Sector Item_Code Total_Consumption_Value      HHID State_code District_Code
#> 1      1       101                     420 715581201         17          1701
#> 2      1       102                     255 715581201         17          1701
#> 3      1       105                      15 715581201         17          1701
#> 4      1       113                      60 715581201         17          1701
#> 5      1       129                     750 715581201         17          1701
#> 6      1       139                      50 715581201         17          1701
#>   Combined_Multiplier
#> 1              324.08
#> 2              324.08
#> 3              324.08
#> 4              324.08
#> 5              324.08
#> 6              324.08
```

## Quick check: cereal spending by sector

Weighted mean monthly household expenditure on cereals (item codes
101–140), rural vs. urban. The `Multiplier` column is the survey weight.

``` r
cereals    <- food[as.integer(food$Item_Code) >= 101 &
                   as.integer(food$Item_Code) <= 140, ]
hh_cereals <- aggregate(Total_Consumption_Value ~ HHID + Sector + Combined_Multiplier,
                        data = cereals, FUN = sum)

rural <- hh_cereals[hh_cereals$Sector == "1", ]
urban <- hh_cereals[hh_cereals$Sector == "2", ]

cat(sprintf(
  "Weighted mean cereal expenditure (Rs/month):\n  Rural: %.0f\n  Urban: %.0f\n",
  weighted.mean(rural$Total_Consumption_Value, rural$Combined_Multiplier, na.rm = TRUE),
  weighted.mean(urban$Total_Consumption_Value, urban$Combined_Multiplier, na.rm = TRUE)
))
#> Weighted mean cereal expenditure (Rs/month):
#>   Rural: 1486
#>   Urban: 1592
```

## Export to csv

[`nesstar_export()`](https://saketkc.github.io/nesstarR/reference/nesstar_export.md)
writes one CSV (or `.csv.gz`) per dataset to a directory. It processes
50,000 rows per chunk by default, so even the 4.65 GB T1 file does not
require loading all rows at once.

``` r
output_dir <- file.path(tempdir(), "nss68t2")
nesstar_export(nb, output_dir = output_dir, compress = FALSE)
#> Wrote: nss68_consumer_expenditure_type2_ds47.csv (101651 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds48.csv (101651 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds49.csv (101651 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds50.csv (464730 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds51.csv (5277850 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds52.csv (1493313 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds53.csv (370071 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds54.csv (2343672 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds55.csv (3436786 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds56.csv (3317537 rows)
#> Wrote: nss68_consumer_expenditure_type2_ds57.csv (101647 rows)
list.files(output_dir)
#>  [1] "nss68_consumer_expenditure_type2_ds47.csv"
#>  [2] "nss68_consumer_expenditure_type2_ds48.csv"
#>  [3] "nss68_consumer_expenditure_type2_ds49.csv"
#>  [4] "nss68_consumer_expenditure_type2_ds50.csv"
#>  [5] "nss68_consumer_expenditure_type2_ds51.csv"
#>  [6] "nss68_consumer_expenditure_type2_ds52.csv"
#>  [7] "nss68_consumer_expenditure_type2_ds53.csv"
#>  [8] "nss68_consumer_expenditure_type2_ds54.csv"
#>  [9] "nss68_consumer_expenditure_type2_ds55.csv"
#> [10] "nss68_consumer_expenditure_type2_ds56.csv"
#> [11] "nss68_consumer_expenditure_type2_ds57.csv"
```

Pass `compress = TRUE` (the default) for gzip-compressed output, which
typically halves file size with negligible extra time.

``` r
nesstar_export(nb,
               output_dir = output_dir,
               datasets   = food_ds,
               compress   = TRUE,
               chunk_size = 100000L)
```

## Verify against Stata reference files

For this, I took help of a colleague to install Nesstar.exe and asked
them to convert the binary to stata file. The code below checks that
nesstarR’s CSV output matches it.

### Unzip the Stata archive

``` r
stata_dir <- file.path(tempdir(), "stata_68t2")
unzip(stata_zip, exdir = stata_dir)
dta_files <- sort(list.files(stata_dir, pattern = "\\.dta$",
                              full.names = TRUE, recursive = TRUE))
cat(length(dta_files), "Stata files found\n")
#> 11 Stata files found
```

### Match datasets by column set

The Stata archive labels each file “Level N”. nesstarR names output
files `_dsNN`. We read only column schemas from the Stata files
(`n_max = 0` loads the header without row data) and match each level to
a CSV by its normalised column name set, which is unique across all 11
datasets.

``` r
library(haven)

# n_max = 0: read header only, no row data loaded
stata_meta <- lapply(dta_files, function(f) {
  df <- read_dta(f, n_max = 0L)
  list(
    path  = f,
    level = as.integer(sub(".*[Ll]evel[_\\s-]*(\\d+).*", "\\1",
                           basename(f), perl = TRUE)),
    ncol  = ncol(df),
    cols  = names(df)
  )
})

csv_files <- sort(list.files(output_dir, pattern = "_ds\\d+\\.csv$",
                              full.names = TRUE))
csv_meta <- lapply(csv_files, function(f) {
  hdr    <- names(read.csv(f, nrows = 0L, check.names = FALSE))
  ds_num <- as.integer(sub(".*_ds(\\d+)\\.csv$", "\\1", basename(f)))
  list(path = f, ds_num = ds_num, cols = hdr)
})

# STATA converts '.' in column names to '_'; normalise before comparing
norm_names <- function(x) toupper(gsub("\\.", "_", trimws(x)))

for (sm in stata_meta) {
  sn <- norm_names(sm$cols)
  cm <- Filter(function(x) setequal(norm_names(x$cols), sn), csv_meta)
  if (length(cm) == 0L) {
    cat(sprintf("Level %2d  cols=%d  -> NO MATCH\n", sm$level, sm$ncol))
    next
  }
  cat(sprintf("Level %2d -> ds%02d  cols=%d  cols_match=TRUE\n",
              sm$level, cm[[1L]]$ds_num, sm$ncol))
}
#> Level  5 -> ds51  cols=32  cols_match=TRUE
#> Level  6 -> ds52  cols=29  cols_match=TRUE
#> Level  4 -> ds50  cols=39  cols_match=TRUE
#> Level  9 -> ds55  cols=36  cols_match=TRUE
#> Level  7 -> ds53  cols=28  cols_match=TRUE
#> Level  8 -> ds53  cols=28  cols_match=TRUE
#> Level  3 -> ds49  cols=35  cols_match=TRUE
#> Level  2 -> ds48  cols=42  cols_match=TRUE
#> Level  1 -> ds47  cols=37  cols_match=TRUE
#> Level 10 -> ds57  cols=41  cols_match=TRUE
#> Level 11 -> ds56  cols=28  cols_match=TRUE
```

Expected output: every Stata level maps to exactly one nesstarR CSV
dataset.

### Spot-check numeric values

Compare the first 500 rows of each matched dataset cell by cell. Any
difference beyond floating-point epsilon (`1e-9`) is flagged.

``` r
SPOT_ROWS <- 500L

for (sm in stata_meta) {
  sn <- norm_names(sm$cols)
  cm <- Filter(function(x) setequal(norm_names(x$cols), sn), csv_meta)
  if (length(cm) == 0L) next
  cm <- cm[[1L]]

  s_df <- read_dta(sm$path, n_max = SPOT_ROWS)
  c_df <- read.csv(cm$path, nrows = SPOT_ROWS, check.names = FALSE)

  s_norm <- norm_names(names(s_df))
  c_norm <- norm_names(names(c_df))
  common <- intersect(s_norm, c_norm)

  mismatches <- 0L
  for (col in common) {
    sv <- suppressWarnings(as.numeric(as.character(
            s_df[[which(s_norm == col)[1L]]])))
    cv <- suppressWarnings(as.numeric(as.character(
            c_df[[which(c_norm == col)[1L]]])))
    if (!all(is.na(sv)) && !all(is.na(cv))) {
      mismatches <- mismatches +
        sum(abs(sv - cv) > 1e-9, na.rm = TRUE) +
        sum(is.na(sv) & !is.na(cv)) +
        sum(!is.na(sv) & is.na(cv))
    } else {
      mismatches <- mismatches +
        sum(trimws(as.character(sv)) != trimws(as.character(cv)), na.rm = TRUE)
    }
  }

  cat(sprintf(
    "Level %2d / ds%02d: %d cols x %d rows - %s\n",
    sm$level, cm$ds_num, length(common), SPOT_ROWS,
    if (mismatches == 0L) "all values match" else paste(mismatches, "MISMATCHES")
  ))
}
#> Level  5 / ds51: 32 cols x 500 rows - all values match
#> Level  6 / ds52: 29 cols x 500 rows - all values match
#> Level  4 / ds50: 39 cols x 500 rows - all values match
#> Level  9 / ds55: 36 cols x 500 rows - all values match
#> Level  7 / ds53: 28 cols x 500 rows - all values match
#> Level  8 / ds53: 28 cols x 500 rows - 6118 MISMATCHES
#> Level  3 / ds49: 35 cols x 500 rows - all values match
#> Level  2 / ds48: 42 cols x 500 rows - all values match
#> Level  1 / ds47: 37 cols x 500 rows - all values match
#> Level 10 / ds57: 41 cols x 500 rows - all values match
#> Level 11 / ds56: 28 cols x 500 rows - all values match
```
