#' Compare a dataset with a reference data frame
#'
#' Compares one dataset of a Nesstar file with the same data from a different
#' source, for example a Stata or SPSS export. Use this function to make sure
#' that nesstarR decodes a file correctly.
#'
#' The function matches the columns by name. Before the match, it changes
#' each group of characters that are not letters or digits to \code{_}, removes
#' \code{_} from the start and the end, and changes the names to upper case.
#' Thus, \code{Srl._No.} and \code{Srl_No} are the same column.
#'
#' If all values in the two columns are numbers, the function compares the
#' numbers. Thus, \code{"010"} and \code{10} are equal. Otherwise, it compares
#' the values as text, without leading and trailing spaces. Empty strings and
#' \code{NA} are equal.
#'
#' Remove value labels from \code{reference} before the comparison, for
#' example with \code{haven::zap_labels()}.
#'
#' @param x A \code{nesstar_binary} object from \code{\link{nesstar_parse}}.
#' @param dataset_number Integer dataset number.
#' @param reference A data frame with the same rows, in the same order.
#' @return A data frame with one row for each column name and these columns:
#'   \describe{
#'     \item{\code{column}}{The column name after the change.}
#'     \item{\code{in_nesstar}, \code{in_reference}}{\code{TRUE} if the
#'       column is in the source.}
#'     \item{\code{different_values}}{The number of rows with different
#'       values. \code{NA} if the column is in only one source.}
#'   }
#' @examples
#' path <- system.file("extdata", "example.Nesstar", package = "nesstarR")
#' x <- nesstar_parse(path)
#' reference <- nesstar_read_dataset(x, dataset_number = 1)
#' reference$AGE[1] <- 26
#' nesstar_compare(x, dataset_number = 1, reference = reference)
#' @export
nesstar_compare <- function(x, dataset_number, reference) {
  stopifnot(inherits(x, "nesstar_binary"))
  ds <- .find_dataset(x, dataset_number)
  if (ds$row_count != nrow(reference)) {
    stop(sprintf(
      "Dataset %d has %d rows, but reference has %d rows.",
      dataset_number, ds$row_count, nrow(reference)
    ))
  }
  vars <- ds$variables
  names(vars) <- .normalize_names(vapply(vars, `[[`, character(1), "name"))
  names(reference) <- .normalize_names(names(reference))

  columns <- union(names(vars), names(reference))
  # decode one column at a time, so only one column of the dataset is in memory
  different <- vapply(columns, function(col) {
    if (!col %in% names(vars) || !col %in% names(reference)) {
      return(NA_integer_)
    }
    value <- .decode_columns(x$path, vars[col], ds$row_count)[[1]]
    .count_differences(value, reference[[col]])
  }, integer(1))

  data.frame(
    column = columns,
    in_nesstar = columns %in% names(vars),
    in_reference = columns %in% names(reference),
    different_values = unname(different)
  )
}

# Stata and SPSS exports change punctuation in names ("Srl._No." -> "Srl_No")
.normalize_names <- function(x) {
  toupper(gsub("^_+|_+$", "", gsub("[^A-Za-z0-9]+", "_", trimws(x))))
}

.count_differences <- function(a, b) {
  # attributes such as format.stata do not change the values; identical()
  # allocates nothing, so equal columns skip the copies below
  a <- as.vector(a)
  b <- as.vector(b)
  if (identical(a, b)) {
    return(0L)
  }
  if (!is.numeric(a) || !is.numeric(b)) {
    a <- trimws(as.character(a))
    b <- trimws(as.character(b))
    a[a == ""] <- NA
    b[b == ""] <- NA
    an <- suppressWarnings(as.numeric(a))
    bn <- suppressWarnings(as.numeric(b))
    # compare as numbers only when no value is lost in the conversion
    if (identical(is.na(an), is.na(a)) && identical(is.na(bn), is.na(b))) {
      a <- an
      b <- bn
    }
  }
  as.integer(sum(xor(is.na(a), is.na(b))) + sum(a != b, na.rm = TRUE))
}
