example_path <- function() system.file("extdata", "example.Nesstar", package = "nesstarR")

nesstar_files <- function(dir) {
  list.files(dir, pattern = "\\.Nesstar$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
}

set_var <- function(x, name, ...) {
  j <- which(vapply(x$datasets[[1]]$variables, `[[`, "", "name") == name)
  x$datasets[[1]]$variables[[j]] <- utils::modifyList(x$datasets[[1]]$variables[[j]], list(...))
  x
}

# control bytes in text mean a numeric column decoded as text
garbage_cols <- function(d) {
  bad <- vapply(d, function(v) {
    is.character(v) && any(grepl("[\x01-\x08\x0e-\x1f]", utils::head(v, 500), useBytes = TRUE))
  }, TRUE)
  names(d)[bad]
}
