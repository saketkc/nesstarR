#' Read the XML metadata of a Nesstar file
#'
#' Decodes the Huffman-coded XML blocks in the file. The XML blocks contain
#' the dataset file names, the variable labels and the category labels.
#'
#' Some older NSS files use different record IDs. For these files, the
#' function cannot decode the metadata. It gives a warning and returns
#' \code{NULL}.
#'
#' @param x A \code{nesstar_binary} object from \code{\link{nesstar_parse}}.
#' @return A named list:
#'   \describe{
#'     \item{\code{datasets}}{A list with one element for each dataset. Each
#'       element contains \code{dataset_number}, \code{file_name} and
#'       \code{variables}. \code{variables} is a list with one list for each
#'       variable. Each variable list contains \code{name}, \code{label} and
#'       \code{categories}.}
#'   }
#'   If the function cannot decode the metadata, it returns \code{NULL}.
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' meta <- nesstar_metadata(x)
#' meta$datasets[[1]]$variables[[1]]$label
#' @export
nesstar_metadata <- function(x) {
  stopifnot(inherits(x, "nesstar_binary"))

  res <- x$resources
  record <- function(id) {
    i <- match(id, res$record_id)
    if (is.na(i)) NULL else list(target_offset = res$target_offset[i], length = res$length[i])
  }

  # Records 1 and 2 are the top-level DocDesc / StudyDesc blocks (modern files)
  if (is.null(record(1)) || is.null(record(2))) {
    warning(
      "Embedded metadata record ids 1 and 2 not found; ",
      "this file uses an older format. Labels are unavailable."
    )
    return(NULL)
  }

  result_datasets <- vector("list", length(x$datasets))

  for (i in seq_along(x$datasets)) {
    ds <- x$datasets[[i]]

    fd_rec <- record(ds$file_description_record_id)
    file_name <- if (!is.null(fd_rec)) {
      xml_text <- tryCatch(
        .decode_huffman_block(x$path, fd_rec),
        error = function(e) NULL
      )
      if (!is.null(xml_text)) .xml_file_name(xml_text) else NULL
    } else {
      NULL
    }

    var_meta <- vector("list", length(ds$variables))
    for (j in seq_along(ds$variables)) {
      v <- ds$variables[[j]]

      label <- ""
      lbl_rec <- record(v$label_resource_id)
      if (!is.null(lbl_rec) && lbl_rec$length > 0) {
        raw_label <- .read_bytes(x$path, lbl_rec$target_offset, lbl_rec$length)
        label <- trimws(rawToChar(raw_label))
      }

      categories <- list()
      cat_rec <- record(v$category_resource_id)
      if (!is.null(cat_rec) && cat_rec$length > 0) {
        xml_text <- tryCatch(
          .decode_huffman_block(x$path, cat_rec),
          error = function(e) NULL
        )
        if (!is.null(xml_text)) {
          categories <- tryCatch(.xml_categories(xml_text), error = function(e) list())
        }
      }

      var_meta[[j]] <- list(
        name       = v$name,
        label      = label,
        categories = categories
      )
    }

    result_datasets[[i]] <- list(
      dataset_number = ds$dataset_number,
      file_name      = file_name %||% paste0("dataset_", sprintf("%02d", ds$dataset_number)),
      variables      = var_meta
    )
  }

  list(datasets = result_datasets)
}

# The resource record gives the length of the block, so only the block is read.
.decode_huffman_block <- function(path, rec) {
  .Call("nesstar_decode_huffman", .read_bytes(path, rec$target_offset, rec$length))
}

.xml_file_name <- function(xml_text) {
  m <- regmatches(xml_text, regexpr("<FileName>([^<]*)</FileName>", xml_text))
  if (length(m) == 0L || !nchar(m)) {
    return(NULL)
  }
  sub("<FileName>([^<]*)</FileName>", "\\1", m)
}

.xml_categories <- function(xml_text) {
  # Simple regex-based extraction; avoids XML parser dependency
  pattern <- 'Value="([^"]*)"[^>]*Label="([^"]*)"'
  m <- gregexpr(pattern, xml_text, perl = TRUE)[[1L]]
  if (m[[1L]] == -1L) {
    return(list())
  }
  starts <- as.integer(m)
  lens <- attr(m, "match.length")
  cats <- vector("list", length(starts))
  for (i in seq_along(starts)) {
    piece <- substr(xml_text, starts[i], starts[i] + lens[i] - 1L)
    val <- sub('Value="([^"]*)".*', "\\1", piece)
    lbl <- sub('.*Label="([^"]*)".*', "\\1", piece)
    cats[[i]] <- list(value = val, label = lbl)
  }
  cats
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
