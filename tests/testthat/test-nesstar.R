example_path <- function() system.file("extdata", "example.Nesstar", package = "nesstarR")

test_that("parse reports datasets and variables", {
  x <- nesstar_parse(example_path())
  expect_s3_class(x, "nesstar_binary")
  expect_equal(nesstar_datasets(x)$row_count, 4L)
  v <- nesstar_variables(x, 1)
  expect_equal(v$name, c("AGE", "GROUP", "INCOME", "NAME"))
  expect_error(nesstar_variables(x, 9), "not found")
})

test_that("columns decode with offsets and missing values", {
  df <- nesstar_read_dataset(nesstar_parse(example_path()), 1)
  expect_equal(df$AGE, c(25, 40, NA, 63))
  expect_equal(df$GROUP, c(11, 12, NA, 13))
  expect_equal(df$INCOME, c(1500.5, NA, 0, 2e6))
  expect_equal(df$NAME, c("ab", "cde", "", "wxyz"))
})

test_that("column subsetting works and rejects unknown names", {
  x <- nesstar_parse(example_path())
  expect_named(nesstar_read_dataset(x, 1, columns = c("NAME", "AGE")), c("AGE", "NAME"))
  expect_error(nesstar_read_dataset(x, 1, columns = "NOPE"), "None of the requested")
})

test_that("chunked export matches a full read", {
  x <- nesstar_parse(example_path())
  dir <- tempfile()
  on.exit(unlink(dir, recursive = TRUE))
  expect_message(
    out <- nesstar_export(x, dir, compress = FALSE, chunk_size = 3L),
    "Wrote"
  )
  got <- utils::read.csv(out, na.strings = "", colClasses = c(NAME = "character"))
  got$NAME[is.na(got$NAME)] <- ""
  expect_equal(got, nesstar_read_dataset(x, 1), ignore_attr = TRUE)
})

test_that("metadata recovers variable labels", {
  meta <- nesstar_metadata(nesstar_parse(example_path()))
  expect_equal(meta$datasets[[1]]$variables[[1]]$label, "Age in years")
})

test_that("malformed input errors instead of crashing", {
  bad <- tempfile()
  on.exit(unlink(bad))
  writeBin(charToRaw("not a nesstar file at all, just text padding....."), bad)
  expect_error(nesstar_parse(bad), "NESSTART")

  # Truncate column data: decoder must refuse rather than read out of bounds.
  x <- nesstar_parse(example_path())
  x$datasets[[1]]$variables[[3]]$data_length <- 8
  expect_error(nesstar_read_dataset(x, 1, columns = "INCOME"), "data region")

  # A column past the end of the file gives an error, not a short column.
  x <- nesstar_parse(example_path())
  x$datasets[[1]]$variables[[1]]$data_offset <- 1e6
  expect_error(nesstar_read_dataset(x, 1, columns = "AGE"), "Could not read")
})

test_that("compare finds changed values and matches punctuated names", {
  x <- nesstar_parse(example_path())
  ref <- nesstar_read_dataset(x, 1)
  ref$AGE <- as.character(ref$AGE)
  ref$AGE[1] <- "025"
  ref$NAME[2] <- " cde "
  ref$INCOME[1] <- 1
  names(ref)[names(ref) == "GROUP"] <- "group."
  ref$EXTRA <- 1
  attr(ref$INCOME, "format.stata") <- "%9.0g"

  cmp <- nesstar_compare(x, 1, ref)
  diffs <- setNames(cmp$different_values, cmp$column)
  expect_equal(
    diffs[c("AGE", "GROUP", "INCOME", "NAME")],
    c(AGE = 0L, GROUP = 0L, INCOME = 1L, NAME = 0L)
  )
  expect_true(is.na(diffs[["EXTRA"]]))
  expect_false(cmp$in_nesstar[cmp$column == "EXTRA"])
  expect_error(nesstar_compare(x, 1, ref[1:2, ]), "reference has 2 rows")
})
