#' Principal Component of Explained Variance
#' 
#' \code{computePCEV} computes the first PCEV and tests its significance.
#' 
#' This is the main function. It computes the PCEV using either the classical 
#' method, block approach or singular .. (TODO). A p-value is also computed, testing the 
#' significance of the PCEV.
#' 
#' The p-value is computed using either a permutation approach or an exact test.
#' The implemented exact tests use Wilks' Lambda (only for a single covariate)
#' or Roy's Largest Root. The latter uses Johnstone's approximation to the null
#' distribution. Note that this test is also available for the block approach,
#' but there is no theoretical guarantee that it works, and the resulting
#' p-value should therefore be compared to that obtained using a permutation
#' procedure.
#' 
#' @seealso \code{\link{estimatePcev}}
#' @param response A matrix of response variables.
#' @param covariate An array or a data frame of covariates.
#' @param confounder An array or data frame of confounders.
#' @param estimation Character string specifying which estimation method to use:
#'   \code{"all"}, \code{"block"} or \code{"singular"}. Default value is \code{"all"}.
#' @param inference Character string specifying which inference method to use: 
#'   \code{"exact"} or \code{"permutation"}. Default value is \code{"exact"}.
#' @param index If \code{estimation = "block"}, \code{index} is a vector describing the
#'   block to which individual response variables correspond.
#' @param distrib If \code{estimation = "singular"}, choose one of the two statistics,
#'   \code{"Wishart"} or \code{"TW"}.
#' @param shrink Should we use a shrinkage estimate of the residual variance? 
#'   Default value is \code{FALSE}..
#' @param nperm The number of permutations to perform if \code{inference = 
#'   "permutation"}
#' @param Wilks Should we use a Wilks test instead of Roy's largest test? This 
#'   is only implemented for a single covariate.
#' @return An object of class \code{Pcev} containing the first PCEV, the 
#'   p-value, the estimate of the shrinkage factor, etc.
#' @examples 
#' set.seed(12345)
#' Y <- matrix(rnorm(100*20), nrow=100)
#' X <- rnorm(100)
#' pcev_out <- computePCEV(Y, X)
#' pcev_out2 <- computePCEV(Y, X, shrink = TRUE)
#' @export
#' @importFrom stats coefficients cor lm.fit model.matrix optim pf
computePCEV <- function(response, covariate, confounder, 
                        estimation = c("all", "block", "singular"), 
                        inference = c("exact", "permutation"), 
                        distrib =  c('Wishart', 'TW'),
                        index = NULL, shrink = FALSE, nperm = 1000, 
                        Wilks = FALSE) {
  # Check input
  estimation <- tryCatch(match.arg(estimation),
                         error = function(c) {
                           stop("Estimation method should be \"all\", \"block\" or \"singular\"", 
                                call. = FALSE)
                         })
  
  inference <- tryCatch(match.arg(inference),
                        error = function(c) {
                          stop("Inference method should be \"exact\" or \"permutation\"", 
                               call. = FALSE)
                        })
  
  distrib <- tryCatch(match.arg(distrib),
                        error = function(c) {
                          stop("Inference method should be \"Wishart\" or \"TW\"", 
                               call. = FALSE)
                        })
  
  if (!is.matrix(response)) {
    stop("The response variables should be passed as a matrix.", call. = FALSE)
  }
  if(missing(confounder)) confounder <- NULL
  
  # We don't allow for missing values
  if(anyNA(response) || anyNA(covariate) || anyNA(confounder)) {
    stop("Missing values are not allowed", call. = FALSE)
  }
  
  if (!is.numeric(index)) index <- NULL
  if (!is.logical(shrink)) shrink <- FALSE
  if (!is.logical(Wilks)) Wilks <- FALSE
  
  # If user gives index, we should do block estimation
  if(!is.null(index)) estimation <- "block"
  
  # Create pcev objects
  if (estimation == "all") {
    pcevObj <- PcevClassical(response,
                             covariate,
                             confounder)
  }
  if (estimation == "block") {
    pcevObj <- PcevBlock(response, 
                         covariate,
                         confounder)
  }
  
  if (Wilks && ncol(pcevObj$X) != 2) {
    warning("Wilks can only be applied with a single covariate")
    Wilks <- FALSE
  }
  if (estimation == "singular") {
    pcevObj <- PcevSingular(response,
                            covariate,
                            confounder)
  }
  
  # Perform estimation and inference
  if (inference == "permutation") {
    pcevRes <- permutePval(pcevObj, shrink, index, nperm)
  } else {
    if (Wilks) {
      pcevRes <- wilksPval(pcevObj, shrink, index)
    } else {
      pcevRes <- roysPval(pcevObj, shrink, distrib, index)
    }
  }
  
  # Compute PCEV
  pcevRes$PCEV <- pcevObj$Y %*% pcevRes$weights
  
  # Compute variable importance
  pcevRes$VIMP <- computeVIMP(pcevObj, pcevRes)
  
  pcevRes$pcevObj <- pcevObj 
  pcevRes$methods <- c(estimation, inference)
  names(pcevRes$methods) <- c("Estimation", "Inference")
  pcevRes$nperm <- nperm 
  pcevRes$Wilks <- Wilks
  pcevRes$shrink <- shrink
  class(pcevRes) <- "Pcev"
  
  # return results
  return(pcevRes)
}

######################################
# Utility functions for estimation----
computeVIMP <- function(pcevObj, list, signed=FALSE) {
  
  VIMP <- cor(pcevObj$Y, list$PCEV)[,1]
  if(!signed) {
    VIMP <- abs(VIMP)
  }
  
  return(VIMP)
}


shrink_est <- function(Vr, res){
  # port of matlab code from http://www.econ.uzh.ch/faculty/wolf/publications.html#9
  # Ledoit, O. and Wolf, M. (2004).
  # Honey, I shrunk the sample covariance matrix.
  # Journal of Portfolio Management 30, Volume 4, 110-119.
  p <- ncol(res); n <- nrow(res)
  
  # Compute sample covariance matrix using the de-meaned returns
  sample <- Vr/n
  
  # Compute prior
  var <- matrix(diag(sample), ncol=1)
  sqrtvar <- sqrt(var)
  tmpMat <- matrix(rep(sqrtvar, p), nrow=p)
  rBar <- (sum(sum(sample / (tmpMat * t(tmpMat)))) - p) / (p * (p - 1))
  prior <- rBar * tmpMat * t(tmpMat)
  diag(prior) <- var
  
  # What is called pi-hat
  y <- res^2
  phiMat <- crossprod(y) / n - 2 * crossprod(res) * sample / n + sample^2
  phi <- sum(phiMat)
  
  # What is called rho-hat
  term1 <- crossprod(res^3, res) / n
  help <- crossprod(res)/ n
  helpDiag <- matrix(diag(help), ncol=1)
  term2 <- matrix(rep(helpDiag, p), ncol=p, byrow=FALSE) * sample
  term3 <- help * matrix(rep(var, p), ncol=p, byrow=FALSE)
  term4 <- matrix(rep(var, p), ncol=p, byrow=FALSE) * sample
  thetaMat <- term1 - term2 - term3 + term4
  diag(thetaMat) <- 0
  rho <- sum(diag(phiMat)) + rBar * sum(sum(tcrossprod(1 / sqrtvar, sqrtvar) * thetaMat))
  
  # What is called gamma-hat
  gamma <- norm(sample - prior, "F")^2
  
  # Compute shrinkage constant
  kappa <- (phi - rho) / gamma
  shrinkage <- max(0, min(1, kappa / n))
  
  # Compute the estimator
  sigma <- shrinkage * prior + (1 - shrinkage) * sample
  sigma <- n * sigma
  out <- list(cov=sigma, rho=shrinkage)
  return(out)
}

#Function to find the level in the factor variable X
#having the strongest effect on Y.

#Anova helper-function
linregfn<- function(y, covars){
  Dis <- covars
  y<-unlist(y)
  modelstring <- "y ~ covars"  
  fit <- lm(as.formula(modelstring))
  resid<-fitted.values(fit)
  sfit <- summary(fit)
  anovF <- anova(fit)
  nc1 <- nrow(sfit$coefficients)
  nc2 <- nrow(anovF) - 1
  pvals <- c(sfit$coefficients[2:nc1, 1], sfit$coefficients[2:nc1,4], anovF[1:nc2,5])
  names(pvals) <- c(paste0('c_', rownames(sfit$coefficients)[2:nc1]), rownames(sfit$coefficients)[2:nc1], rownames(anovF)[1:nc2])
  return(list(pvals=pvals, resid=resid))
}

#function to find the most deviant subpopulation of samples
#' @export
fimp<-function(data, covars){
  pvals<-list()
  l <- unique(covars)
  for (i in l){
    cnew <- ifelse(covars==i,1,0)
    resFn <- linregfn(data, as.factor(cnew))
    pvals <- c(pvals, resFn$pvals['covars'])
  }
  allp<-linregfn(data, as.factor(covars))$pvals['covars']
  minp<-which(unlist(pvals)==min(unlist(pvals))); 
  return(list(minp=minp, pval=pvals[minp], lev = l[minp], allp=allp))
}

###########################
# Constructor functions----

#' Constructor functions for the different pcev objects
#' 
#' \code{PcevClassical}, \code{PcevBlock} and \code{PcevSingular} create the pcev objects from the 
#' provided data that are necessary to compute the PCEV according to the user's 
#' parameters.
#' 
#' @seealso \code{\link{estimatePcev}}, \code{\link{computePCEV}}
#' @param response A matrix of response variables.
#' @param covariate A matrix or a data frame of covariates.
#' @param confounder A matrix or data frame of confounders
#' @return A pcev object, of the class that corresponds to the estimation 
#'   method. These objects are lists that contain the data necessary for
#'   computation.
#' @name PcevObj
NULL

#' @rdname PcevObj
#' @export
PcevClassical <- function(response, covariate, confounder) {
  if(is.null(confounder)) {
    structure(list(Y = response, 
                   X = model.matrix(~., as.data.frame(covariate)),
                   Z = c()), 
              class = "PcevClassical")
  } else {
    structure(list(Y = response, 
                   X = model.matrix(~., as.data.frame(covariate)), 
                   Z = model.matrix(~., as.data.frame(confounder))[,-1]), 
              class = "PcevClassical")
  }
  
}

#' @rdname PcevObj
#' @export 
PcevBlock <- function(response, covariate, confounder) {
  if(is.null(confounder)) {
    structure(list(Y = response, 
                   X = model.matrix(~., as.data.frame(covariate)), 
                   Z = c()), 
              class = "PcevBlock")
  } else {
    structure(list(Y = response, 
                   X = model.matrix(~., as.data.frame(covariate)), 
                   Z = model.matrix(~., as.data.frame(confounder))[,-1]), 
              class = "PcevBlock")
  }
  
}

#' @rdname PcevObj
#' @export
PcevSingular <- function(response, covariate, confounder) {
  if(is.null(confounder)) {
    structure(list(Y = response, 
                   X = model.matrix(~., as.data.frame(covariate)),
                   Z = c()), 
              class = "PcevSingular")
  } else {
    structure(list(Y = response, 
                   X = model.matrix(~., as.data.frame(covariate)), 
                   Z = model.matrix(~., as.data.frame(confounder))[,-1]), 
              class = "PcevSingular")
  }
  
}

####################################
# Documentation for the datasets----

#' Methylation values around BLK gene
#' 
#' A dataset containing methylation values for cell-separated samples. The 
#' methylation was measured using bisulfite sequencing. The data also contains 
#' the genomic position of these CpG sites, as well as a binary phenotype 
#' (i.e. whether the sample comes from a B cell).
#' 
#' Methylation was first measured at 24,068 sites, on 40 samples. Filtering was
#' performed to keep the 25\% most variable sites. See the vignette for more detail.
#' 
#' @format The data comes in four objects:
#' \describe{
#' \item{methylation}{Matrix of methylation values at 5,986 sites measured on 40 samples}
#' \item{pheno}{Vector of phenotype, indicating whether the sample comes from a B cell}
#' \item{position}{Data frame recording the position of each CpG site along the BLK region}
#' \item{index}{Index vector used in the computation of PCEV-block}
#' }
#' @source Tomi Pastinen, McGill University, GEnome Quebec.
"methylation"

#' @rdname methylation
"pheno"

#' @rdname methylation
"position"

#' @rdname methylation
"index"
