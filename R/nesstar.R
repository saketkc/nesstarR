#' Parse a Nesstar file
#'
#' Decodes the resource index, the dataset descriptors and the variable
#' directories. Does not decode row data.
#'
#' The function does not keep the file in memory. The other functions read
#' only the bytes that they need from the file. Thus, the memory use does not
#' increase with the file size. Do not move or change the file while you use
#' the result.
#'
#' @param path Path to a \code{.Nesstar} file.
#' @return A \code{nesstar_binary} list (S3 class).
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' x
#' @export
nesstar_parse <- function(path) {
  path <- normalizePath(path, mustWork = TRUE)
  parsed <- .Call(
    "nesstar_parse_binary",
    function(offset, n) .read_bytes(path, offset, n),
    file.info(path)$size
  )
  structure(
    list(
      path       = path,
      byte_order = parsed$byte_order,
      resources  = parsed$resources,
      datasets   = parsed$datasets
    ),
    class = "nesstar_binary"
  )
}

#' @export
print.nesstar_binary <- function(x, ...) {
  cat("<nesstar_binary>\n")
  cat(" File      :", basename(x$path), "\n")
  cat(" Datasets  :", length(x$datasets), "\n")
  invisible(x)
}

#' List the datasets in a Nesstar file
#'
#' @param x A \code{nesstar_binary} object from \code{\link{nesstar_parse}}.
#' @return A data frame with columns \code{dataset_number}, \code{row_count},
#'   \code{variable_count}.
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' nesstar_datasets(x)
#' @export
nesstar_datasets <- function(x) {
  stopifnot(inherits(x, "nesstar_binary"))
  rows <- lapply(x$datasets, function(ds) {
    data.frame(
      dataset_number = ds$dataset_number,
      row_count = ds$row_count,
      variable_count = ds$variable_count,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

#' List variables in one dataset
#'
#' @param x A \code{nesstar_binary} object.
#' @param dataset_number Integer dataset number (as shown by
#'   \code{\link{nesstar_datasets}}).
#' @return A data frame with one row for each variable. The columns give the
#'   storage format of the variable.
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' nesstar_variables(x, dataset_number = 1)
#' @export
nesstar_variables <- function(x, dataset_number) {
  stopifnot(inherits(x, "nesstar_binary"))
  ds <- .find_dataset(x, dataset_number)
  rows <- lapply(ds$variables, function(v) {
    data.frame(
      name               = v$name,
      variable_id        = v$variable_id,
      mode_code          = v$mode_code,
      value_format_code  = v$value_format_code,
      value_offset_i64   = v$value_offset_i64,
      width_value        = v$width_value,
      data_offset        = v$data_offset,
      data_length        = v$data_length,
      stringsAsFactors   = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Read one dataset into an R data frame
#'
#' Numeric columns (mode 5) become \code{numeric}. String columns (mode 1)
#' become \code{character}. Missing values become \code{NA}.
#'
#' @param x A \code{nesstar_binary} object.
#' @param dataset_number Integer dataset number.
#' @param columns Character vector of the column names to read. If
#'   \code{NULL} (the default), the function reads all columns.
#' @return A \code{data.frame}.
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' nesstar_read_dataset(x, dataset_number = 1)
#' nesstar_read_dataset(x, dataset_number = 1, columns = c("AGE", "NAME"))
#' @export
nesstar_read_dataset <- function(x, dataset_number, columns = NULL) {
  stopifnot(inherits(x, "nesstar_binary"))
  ds <- .find_dataset(x, dataset_number)
  vars <- ds$variables

  if (!is.null(columns)) {
    keep <- vapply(vars, function(v) v$name %in% columns, logical(1))
    vars <- vars[keep]
    if (length(vars) == 0L) {
      stop("None of the requested columns found in dataset ", dataset_number)
    }
  }

  cols <- .decode_columns(x$path, vars, ds$row_count)
  as.data.frame(cols, stringsAsFactors = FALSE, check.names = FALSE)
}

#' Export datasets to CSV files
#'
#' Writes each dataset to a different CSV file. The file name contains the
#' name of the Nesstar file and the dataset number.
#'
#' @param x A \code{nesstar_binary} object.
#' @param output_dir Directory for the output files. If the directory does
#'   not exist, the function makes it.
#' @param datasets Integer vector of the dataset numbers to export. If
#'   \code{NULL} (the default), the function exports all datasets.
#' @param compress Logical. If \code{TRUE} (the default), the function writes
#'   gzip files (\code{.csv.gz}).
#' @param chunk_size Number of rows to read at a time. A smaller value
#'   decreases the memory use.
#' @return Invisibly, a character vector of output file paths.
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' out <- nesstar_export(x, output_dir = tempdir())
#' read.csv(out[1])
#' @export
nesstar_export <- function(x, output_dir, datasets = NULL,
                           compress = TRUE, chunk_size = 50000L) {
  stopifnot(inherits(x, "nesstar_binary"))
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  stem <- tools::file_path_sans_ext(basename(x$path))
  to_write <- x$datasets
  if (!is.null(datasets)) {
    to_write <- Filter(function(ds) ds$dataset_number %in% datasets, to_write)
  }

  paths <- character(length(to_write))

  for (i in seq_along(to_write)) {
    ds <- to_write[[i]]
    ext <- if (compress) ".csv.gz" else ".csv"
    out_path <- file.path(
      output_dir,
      paste0(stem, "_ds", sprintf("%02d", ds$dataset_number), ext)
    )
    vars <- ds$variables
    nrow <- ds$row_count

    con <- if (compress) gzfile(out_path, "wt") else file(out_path, "wt")
    on.exit(try(close(con), silent = TRUE), add = TRUE)

    first_chunk <- TRUE
    row <- 0L
    while (row < nrow) {
      n_rows <- min(chunk_size, nrow - row)
      chunk <- .decode_columns(x$path, vars, nrow, row, n_rows)
      df <- as.data.frame(chunk, stringsAsFactors = FALSE, check.names = FALSE)
      utils::write.table(df,
        file = con, sep = ",", row.names = FALSE,
        col.names = first_chunk, na = "",
        fileEncoding = "UTF-8", quote = TRUE,
        qmethod = "double"
      )
      first_chunk <- FALSE
      row <- row + n_rows
    }

    close(con)
    on.exit(NULL)
    paths[i] <- out_path
    message("Wrote: ", basename(out_path), " (", nrow, " rows)")
  }

  invisible(paths)
}

.find_dataset <- function(x, dataset_number) {
  for (ds in x$datasets) {
    if (ds$dataset_number == dataset_number) {
      return(ds)
    }
  }
  stop(
    "Dataset ", dataset_number, " not found. Available: ",
    paste(vapply(x$datasets, `[[`, integer(1), "dataset_number"), collapse = ", ")
  )
}

# Read n bytes at the 0-based offset of the file.
.read_bytes <- function(path, offset, n) {
  con <- file(path, "rb")
  on.exit(close(con))
  seek(con, offset)
  bytes <- readBin(con, "raw", n)
  if (length(bytes) != n) {
    stop("Could not read ", n, " bytes at offset ", offset, " of ", path)
  }
  bytes
}

# Decode rows row_start to row_start + n_rows - 1 (0-based) of each variable.
# The C decoder reads only the bytes of these rows. total_nrow is needed to
# resolve mode_code=0 variables.
.decode_columns <- function(path, vars, total_nrow,
                            row_start = 0L, n_rows = total_nrow) {
  read <- function(offset, n) .read_bytes(path, offset, n)
  cols <- lapply(vars, function(v) {
    if (v$data_length == 0 || !v$mode_code %in% c(0L, 1L, 5L)) {
      return(if (v$mode_code == 1L) character(n_rows) else rep(NA_real_, n_rows))
    }
    .Call(
      "nesstar_decode_column_range",
      read,
      v$data_offset,
      v$data_length,
      v$mode_code,
      v$value_format_code,
      v$value_offset_i64,
      v$width_value,
      as.integer(total_nrow),
      as.integer(row_start),
      as.integer(n_rows)
    )
  })
  names(cols) <- vapply(vars, `[[`, character(1), "name")
  cols
}
