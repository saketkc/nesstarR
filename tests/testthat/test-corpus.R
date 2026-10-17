corpus_files <- function() {
  dir <- Sys.getenv("NESSTAR_CORPUS_DIR")
  if (!nzchar(dir)) return(character())
  nesstar_files(dir)
}

test_that("every dataset of every corpus file reads without garbage", {
  files <- corpus_files()
  skip_if(length(files) == 0, "set NESSTAR_CORPUS_DIR to a folder of .Nesstar files")
  for (f in files) {
    x <- nesstar_parse(f)
    for (ds in x$datasets) {
      info <- paste(basename(f), "dataset", ds$dataset_number)
      d <- expect_no_error(nesstar_read_dataset(x, ds$dataset_number), message = info)
      expect_equal(nrow(d), ds$row_count, info = info)
      expect_equal(garbage_cols(d), character(), info = info)
    }
  }
})
