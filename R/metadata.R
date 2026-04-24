#' Read embedded XML metadata from a NESSTAR container
#'
#' Decodes the Huffman-compressed XML blocks embedded in the container to
#' recover dataset file names, variable labels, and categorical value labels.
#'
#' If the embedded metadata blocks cannot be decoded (e.g. older NSS files
#' where record IDs differ) the function returns \code{NULL} with a warning
#' instead of stopping.
#'
#' @param x A \code{nesstar_binary} object from \code{\link{nesstar_parse}}.
#' @return A named list:
#'   \describe{
#'     \item{\code{datasets}}{A list, one element per dataset, each containing
#'       \code{dataset_number}, \code{file_name}, and \code{variables} (a list
#'       of per-variable lists with \code{name}, \code{label}, and
#'       \code{categories}).}
#'   }
#'   Returns \code{NULL} (with a warning) when metadata cannot be decoded.
#' @export
nesstar_metadata <- function(x) {
  stopifnot(inherits(x, "nesstar_binary"))

  idx <- .build_resource_index(x$raw)

  # Records 1 and 2 are the top-level DocDesc / StudyDesc blocks (modern files)
  rec1 <- idx[[as.character(1L)]]
  rec2 <- idx[[as.character(2L)]]
  if (is.null(rec1) || is.null(rec2)) {
    warning(
      "Embedded metadata record ids 1 and 2 not found; ",
      "this file uses an older format. Labels are unavailable."
    )
    return(NULL)
  }

  result_datasets <- vector("list", length(x$datasets))

  for (i in seq_along(x$datasets)) {
    ds <- x$datasets[[i]]

    fd_rec <- idx[[as.character(ds$file_description_record_id)]]
    file_name <- if (!is.null(fd_rec)) {
      xml_text <- tryCatch(
        .decode_huffman_block(x$raw, fd_rec$target_offset, has_ds_idx = FALSE),
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
      lbl_rec <- idx[[as.character(v$label_resource_id)]]
      if (!is.null(lbl_rec) && lbl_rec$length > 0) {
        raw_label <- x$raw[(lbl_rec$target_offset + 1L):(lbl_rec$target_offset + lbl_rec$length)]
        label <- trimws(rawToChar(raw_label))
      }

      categories <- list()
      cat_rec <- idx[[as.character(v$category_resource_id)]]
      if (!is.null(cat_rec) && cat_rec$length > 0) {
        xml_text <- tryCatch(
          .decode_huffman_block(x$raw, cat_rec$target_offset, has_ds_idx = FALSE),
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

.build_resource_index <- function(raw) {
  # Detect byte order: LE offset at 0x25 valid?
  le_off <- .u32le(raw, 0x26L) # R is 1-based; byte 0x25 = index 38
  be_off <- .u32be(raw, 0x26L)
  file_len <- length(raw)
  le <- if (le_off + 4L <= file_len) TRUE else FALSE

  idx_off <- if (le) le_off else be_off
  count <- if (le) .u32le(raw, idx_off + 1L) else .u32be(raw, idx_off + 1L)

  result <- vector("list", count)
  pos <- idx_off + 4L + 1L # 1-based
  for (i in seq_len(count)) {
    rid <- if (le) .u32le(raw, pos) else .u32be(raw, pos)
    tgt <- if (le) .u32le(raw, pos + 4L) else .u32be(raw, pos + 4L)
    length <- if (le) .u32le(raw, pos + 10L) else .u32be(raw, pos + 10L)
    result[[i]] <- list(record_id = rid, target_offset = tgt, length = length)
    pos <- pos + 15L
  }

  named <- list()
  for (r in result) named[[as.character(r$record_id)]] <- r
  named
}

.decode_huffman_block <- function(raw, target_offset, has_ds_idx = FALSE) {
  # target_offset is 0-based; convert to 1-based R index
  .Call(
    "nesstar_decode_huffman", raw,
    as.integer(target_offset),
    as.logical(has_ds_idx)
  )
}

# Extract <FileName> text from a FileDesc XML string
.xml_file_name <- function(xml_text) {
  m <- regmatches(xml_text, regexpr("<FileName>([^<]*)</FileName>", xml_text))
  if (length(m) == 0L || !nchar(m)) {
    return(NULL)
  }
  sub("<FileName>([^<]*)</FileName>", "\\1", m)
}

# Extract Category Value/Label pairs from a Categories XML string
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

# Little-endian u32 from a raw vector (1-based offset)
.u32le <- function(raw, off) {
  as.integer(raw[off]) +
    as.integer(raw[off + 1L]) * 256L +
    as.integer(raw[off + 2L]) * 65536L +
    bitwShiftL(as.integer(raw[off + 3L]), 24L)
}

# Big-endian u32
.u32be <- function(raw, off) {
  bitwShiftL(as.integer(raw[off]), 24L) +
    as.integer(raw[off + 1L]) * 65536L +
    as.integer(raw[off + 2L]) * 256L +
    as.integer(raw[off + 3L])
}

# Null-coalescing helper
`%||%` <- function(a, b) if (!is.null(a)) a else b
