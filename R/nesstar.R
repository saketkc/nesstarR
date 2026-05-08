#' Parse a NESSTAR binary container
#'
#' Reads the file into memory and parses the binary layout (resource index,
#' dataset descriptors, variable directories).
#'
#' @param path Path to a \code{.Nesstar} file.
#' @return A \code{nesstar_binary} list (S3 class).
#' @export
nesstar_parse <- function(path) {
  path <- normalizePath(path, mustWork = TRUE)
  raw <- readBin(path, what = "raw", n = file.info(path)$size)
  parsed <- .Call("nesstar_parse_binary", raw)
  structure(
    list(
      path       = path,
      raw        = raw,
      byte_order = parsed$byte_order,
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

#' List datasets in a parsed NESSTAR container
#'
#' @param x A \code{nesstar_binary} object from \code{\link{nesstar_parse}}.
#' @return A data frame with columns \code{dataset_number}, \code{row_count},
#'   \code{variable_count}.
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
#' @return A data frame with one row per variable describing its storage
#'   properties.
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
#' Numeric columns (mode 5) become \code{numeric}; string columns (mode 1)
#' become \code{character}.  Missing values are \code{NA}.
#'
#' @param x A \code{nesstar_binary} object.
#' @param dataset_number Integer dataset number.
#' @param columns Optional character vector of column names to read.  When
#'   \code{NULL} (default) all columns are returned.
#' @return A \code{data.frame}.
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

  cols <- .decode_columns(x$raw, vars, ds$row_count)
  as.data.frame(cols, stringsAsFactors = FALSE, check.names = FALSE)
}

#' Export all datasets to CSV files
#'
#' Writes each dataset to a CSV file named after the container and dataset
#' number.
#'
#' @param x A \code{nesstar_binary} object.
#' @param output_dir Directory to write files into.  Created if it does not
#'   exist.
#' @param datasets Integer vector of dataset numbers to export.  When
#'   \code{NULL} (default) every dataset is exported.
#' @param compress Logical; when \code{TRUE} (default) output files are
#'   gzip-compressed (\code{.csv.gz}).
#' @param chunk_size Number of rows to process per iteration (reduces peak
#'   memory use).
#' @return Invisibly, a character vector of output file paths.
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
    col_names <- vapply(vars, `[[`, character(1), "name")

    con <- if (compress) gzfile(out_path, "wt") else file(out_path, "wt")
    on.exit(try(close(con), silent = TRUE), add = TRUE)

    first_chunk <- TRUE
    row <- 0L
    while (row < nrow) {
      n_rows <- min(chunk_size, nrow - row)
      chunk <- .decode_columns_range(x$raw, vars, row, n_rows, nrow)
      df <- as.data.frame(
        setNames(chunk, col_names),
        stringsAsFactors = FALSE, check.names = FALSE
      )
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

# Resolve the true mode for a mode_code=0 variable by checking whether
# data_length matches mode 5 (numeric) or mode 1 (fixed-width string).
# Some older NSS files write mode_code=0 for both numeric columns (e.g.
# Subsample_multiplier, value_format_code=10/float64) and string columns
# (e.g. HH_Type_code, value_format_code=2/nibble but stored as 2-byte ASCII).
# The data_length is the definitive discriminator:
#   mode 5 expected bytes: nibble=ceil(n/2), byte=n, u16=2n, ..., f64=8n
#   mode 1 expected bytes: n * width_value
.resolve_mode0 <- function(v, total_nrow) {
  mode5_bytes <- switch(as.character(v$value_format_code),
    "2"  = (total_nrow + 1L) %/% 2L, # FMT_NIBBLE: 4 bits/row
    "3"  = total_nrow, # FMT_BYTE
    "4"  = total_nrow * 2L, # FMT_UINT16
    "5"  = total_nrow * 3L, # FMT_UINT24
    "6"  = total_nrow * 4L, # FMT_UINT32
    "7"  = total_nrow * 5L, # FMT_UINT40
    "10" = total_nrow * 8L, # FMT_FLOAT64
    NA_integer_
  )
  if (!is.na(mode5_bytes) && v$data_length == mode5_bytes) 5L else 1L
}

.decode_columns <- function(raw, vars, nrow) {
  cols <- vector("list", length(vars))
  names(cols) <- vapply(vars, `[[`, character(1), "name")
  for (i in seq_along(vars)) {
    v <- vars[[i]]
    effective_mode <- if (v$mode_code == 0L && v$data_length > 0L) {
      .resolve_mode0(v, nrow)
    } else {
      v$mode_code
    }
    if (v$data_length == 0L || !effective_mode %in% c(1L, 5L)) {
      cols[[i]] <- if (effective_mode == 1L) character(nrow) else rep(NA_real_, nrow)
      next
    }
    cols[[i]] <- .Call(
      "nesstar_decode_column",
      raw,
      v$data_offset,
      v$data_length,
      effective_mode,
      v$value_format_code,
      v$value_offset_i64,
      v$width_value,
      nrow
    )
  }
  cols
}

# total_nrow is needed to resolve mode_code=0 variables.
.decode_columns_range <- function(raw, vars, row_start, n_rows, total_nrow) {
  cols <- vector("list", length(vars))
  for (i in seq_along(vars)) {
    v <- vars[[i]]
    effective_mode <- if (v$mode_code == 0L && v$data_length > 0L) {
      .resolve_mode0(v, total_nrow)
    } else {
      v$mode_code
    }
    if (v$data_length == 0L || !effective_mode %in% c(1L, 5L)) {
      cols[[i]] <- if (effective_mode == 1L) character(n_rows) else rep(NA_real_, n_rows)
      next
    }
    cols[[i]] <- .Call(
      "nesstar_decode_column_range",
      raw,
      v$data_offset,
      v$data_length,
      effective_mode,
      v$value_format_code,
      v$value_offset_i64,
      v$width_value,
      row_start,
      n_rows
    )
  }
  cols
}
