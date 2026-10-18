# older files (NSS 52nd round) mark numbers as text, pad regions and misdeclare widths

test_that("a numeric column marked as text (mode 1) decodes as a number", {
  x <- nesstar_parse(example_path())
  # AGE: 4 bytes as numbers, 8 as text
  x <- set_var(x, "AGE", mode_code = 1L, width_value = 2L)
  # GROUP: 2 bytes as nibbles, 4 as text
  x <- set_var(x, "GROUP", mode_code = 1L, width_value = 1L)
  df <- nesstar_read_dataset(x, 1)
  expect_equal(df$AGE, c(25, 40, NA, 63))
  expect_equal(df$GROUP, c(11, 12, NA, 13))
  expect_equal(df$NAME, c("ab", "cde", "", "wxyz"))
})

test_that("a mode-0 float64 column with a blocked data region decodes the first n doubles", {
  x <- nesstar_parse(example_path())
  # float64 padded to 8 * (2n + 100) bytes, values first
  x <- set_var(x, "INCOME", mode_code = 0L, data_length = 8 * (2 * 4 + 100))
  expect_equal(nesstar_read_dataset(x, 1)$INCOME, c(1500.5, NA, 0, 2e6))
})

test_that("a mode-0 float64 column with 2 * 8 bytes per row decodes the first n doubles", {
  x <- nesstar_parse(example_path())
  # NSS 68th Type 1 Combined_multiplier: 16 bytes per row, declared width 9
  x <- set_var(x, "INCOME", mode_code = 0L, width_value = 9L, data_length = 2 * 8 * 4)
  expect_equal(nesstar_read_dataset(x, 1)$INCOME, c(1500.5, NA, 0, 2e6))
})

test_that("a text column with a wrong width and a blocked data region uses the true width", {
  x <- nesstar_parse(example_path())
  # stored width 4, declared 10, like 52nd-round STATE
  x <- set_var(x, "NAME", width_value = 10L, data_length = 4 * (2 * 4 + 100))
  expect_equal(nesstar_read_dataset(x, 1)$NAME, c("ab", "cde", "", "wxyz"))
})

test_that("a data region too short for any mode still errors", {
  x <- set_var(nesstar_parse(example_path()), "AGE", mode_code = 1L, width_value = 2L, data_length = 3)
  expect_error(nesstar_read_dataset(x, 1, columns = "AGE"), "data region")
})

# real NSS microdata cannot be redistributed
nss52_path <- function() {
  p <- Sys.getenv("NESSTAR_52_PATH")
  if (nzchar(p)) return(p)
  f <- nesstar_files(path.expand("~/data/nss_health_raw/IND-NSSO-SHC-1995-v2.1"))
  if (length(f)) f[1] else ""
}

test_that("NSS 52nd round: every dataset reads, with plausible numbers", {
  path <- nss52_path()
  skip_if_not(file.exists(path), "NSS 52nd-round Nesstar file not available")
  x <- nesstar_parse(path)

  # STATE is declared width 10 but stored as 2
  keep <- list()
  for (ds in nesstar_datasets(x)$dataset_number) {
    info <- paste("dataset", ds)
    d <- expect_no_error(nesstar_read_dataset(x, ds), message = info)
    expect_equal(garbage_cols(d), character(), info = info)
    expect_equal(as.character(d$STATE), substr(as.character(d$STATE_REGION_DISTRICT), 1, 2), info = info)
    if (ds %in% c(1, 2, 19)) keep[[as.character(ds)]] <- d
  }

  persons <- keep[["2"]]
  expect_true(is.numeric(persons$AGE))
  expect_true(all(persons$AGE >= 0 & persons$AGE <= 110, na.rm = TRUE))
  expect_true(all(persons$GEN_EDUCATION %in% 0:13))
  # person weight; sums to India's 1995-96 population
  expect_true(is.numeric(persons$MULT_COMB) && all(persons$MULT_COMB > 0))
  expect_gt(sum(persons$MULT_COMB), 7e8)
  expect_lt(sum(persons$MULT_COMB), 1.1e9)

  hh <- keep[["1"]]
  expect_true(all(hh$HH_SIZE >= 1 & hh$HH_SIZE <= 60))
  expect_true(all(hh$HH_MON_CON_EXP > 0))
  expect_equal(stats::median(hh$MPCE, na.rm = TRUE), 363)

  hosp <- keep[["19"]]
  expect_equal(nrow(hosp), 26526L)
  expect_true(all(hosp$AGE >= 0 & hosp$AGE <= 110, na.rm = TRUE))
})
