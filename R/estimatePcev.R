#' Estimation of PCEV
#' 
#' \code{estimatePcev} estimates the PCEV.
#' 
#' @seealso \code{\link{computePCEV}}
#' @param pcevObj A pcev object of class \code{PcevClassical} or 
#'   \code{PcevBlock}
#' @param shrink Should we use a shrinkage estimate of the residual variance? 
#' @param index If \code{pcevObj} is of class \code{PcevBlock}, index is a vector
#'   describing the block to which individual response variables correspond.
#' @param ... Extra parameters.
#' @return A list containing the variance components, the first PCEV, the 
#'   eigenvalues of \eqn{V_R^{-1}V_G} and the estimate of the shrinkage 
#'   parameter \eqn{\rho}
#' @export 
estimatePcev <- function(pcevObj, ...) UseMethod("estimatePcev")

#' @describeIn  estimatePcev
estimatePcev.default <- function(pcevObj, ...) {
  stop(strwrap("This function should be used with a Pcev object of class 
               PcevClassical or PcevBlock"))
}

#' @describeIn estimatePcev
estimatePcev.PcevClassical <- function(pcevObj, shrink, ...) {
  #initializing parameters
  rho <- NULL
  Y <- pcevObj$Y
  N <- nrow(Y)
  p <- ncol(Y)
  bar.Y <- colMeans(Y)
  
  # Variance decomposition
  fit <- lm.fit(cbind(pcevObj$X, pcevObj$Z), Y)
  Yfit <- fit$fitted.values
  res <- Y - Yfit
  fit_confounder <- lm.fit(cbind(rep_len(1, N), pcevObj$Z), Y)
  Yfit_confounder <- fit_confounder$fitted.values
  
  Vr <- crossprod(res, Y)
  Vm <- crossprod(Yfit - Yfit_confounder, Y)
  
  # Shrinkage estimate of Vr
  if (shrink) Vr <- shrink(Vr)
  
  # Computing PCEV
  temp <- eigen(Vr, symmetric=TRUE)
  Ur <- temp$vectors
  diagD <- temp$values
  value <- 1/sqrt(diagD)
  root.Vr <- Ur %*% diag(value, nrow = length(value)) %*% t(Ur)
  mainMatrix <- root.Vr %*% Vm %*% root.Vr
  temp1 <- eigen(mainMatrix, symmetric=TRUE)
  weights <- root.Vr %*% temp1$vectors
  d <- temp1$values
  
  return(list("residual" = Vr,
              "model" = Vm,
              "weights" = weights[,1, drop=FALSE],
              "rootVr" = root.Vr,
              "largestRoot" = d[1],
              "rho" = rho))
}

#' @describeIn estimatePcev
estimatePcev.PcevBlock <- function(pcevObj, shrink, index, ...) {
  p <- ncol(pcevObj$Y)
  N <- nrow(pcevObj$Y)
  
  if (is.null(index) || p != length(index)) {
    stop("index should have length equal to number of response variables")
  }
  
  d <- length(unique(index))
  if(d > N && ncol(pcevObj$X) != 2) {
    warning("It is recommended to have a number of blocks smaller than the number of observations")
  }
  Ypcev <- matrix(NA, nrow = N, ncol = d)
  weights <- rep_len(0, p)
  rootVr <- list("first" = vector("list", d), 
                 "second" = NA)
  
  counter <- 0
  for (i in unique(index)) {
    counter <- counter + 1
    pcevObj_red <- pcevObj 
    pcevObj_red$Y <- pcevObj$Y[, index == i, drop = FALSE]
    class(pcevObj_red) <- "PcevClassical"
    result <- estimatePcev(pcevObj_red, shrink)
    weights[index==i] <- result$weights
    Ypcev[,counter] <- pcevObj_red$Y %*% weights[index==i]
    rootVr$first[[counter]] <- result$rootVr
  }
  
  pcevObj_total <- pcevObj
  pcevObj_total$Y <- Ypcev
  class(pcevObj_total) <- "PcevClassical"
  
  if (ncol(pcevObj_total$X) == 2) {
    fit_total <- lm.fit(pcevObj_total$X, pcevObj_total$Y)
    beta_total <- coefficients(fit_total)[2,]
    weight_step2 <- beta_total/crossprod(beta_total)
    
  } else {
    result <- estimatePcev(pcevObj_total, shrink)
    weight_step2 <- result$weights
    rootVr$second <- result$rootVr
  }
  
  counter <- 0
  for (i in unique(index)) {
    counter <- counter + 1
    weights[index==i] <- weights[index==i]*weight_step2[counter]
  }
  
  return(list("weights" = weights,
              "rootVr" = rootVr))
}