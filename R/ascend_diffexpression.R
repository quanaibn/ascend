# Code for differential expression Requires DESeq to run, and parallel

#' RunDESeq
#'
# Called by RunDiffExpression in parallel. This performs the differential expression part.
RunDESeq <- function(data, condition.list = list(), condition.a = NULL, condition.b = NULL, fitType = NULL, method = NULL) {
    library(DESeq)
    count.dataset <- DESeq::newCountDataSet(data, condition.list)
    count.dataset <- DESeq::estimateSizeFactors(count.dataset)
    dispersions <- DESeq::estimateDispersions(count.dataset, method = method, fitType = fitType)
    de.seq.results <- DESeq::nbinomTest(dispersions, condition.a, condition.b)
    return(de.seq.results)
}

#' ProcessDEREsults
#'
#' Called by RunDiffExpression. Compiles the resultant data into data frames and converts
#' the results to absolute fold change.
#'
ProcessDEResults <- function(output.list) {
    de.result.df <- dplyr::bind_rows(output.list)

    # Adjust Foldchange
    print("Adjusting fold change values...")
    adjusted.foldchange <- (de.result.df$baseMeanB - 1)/(de.result.df$baseMeanA - 1)
    log2.adjusted.foldchange <- log2(adjusted.foldchange)
    de.result.df$foldChange <- adjusted.foldchange
    de.result.df$log2FoldChange <- log2.adjusted.foldchange
    de.result.df <- de.result.df[order(de.result.df$pval, decreasing = F), ]
    return(de.result.df)
}

#' PrepareCountData
#'
#' Called by RunDiffExpression. This chunks up the expression matrix to feed into DESeq.
#'
PrepareCountData <- function(object, cells, ngenes) {
    if (is.null(ngenes)){
      ngenes <- nrow(object@ExpressionMatrix)
    }
  
    # Retrieve information from EMSet
    expression.matrix <- GetExpressionMatrix(object, "matrix")
    expression.matrix <- expression.matrix[ ,cells]
    
    # Filter out genes with zero expression, and add one to make it friendly for DESeq
    print("Rounding expression matrix values...")
    ordered.genes <- object@Metrics$TopGeneList
    
    # Identify which genes to keep
    ## 1. They need to be within the top genes that the user has specified
    ## 2. The mean of these genes need to be greater than zero
    ## 3. Their standard deviation needs to be greater than zero
    
    top.genes <- ordered.genes[1:ngenes]
    mean.gene.expression <- rownames(expression.matrix)[which(rowMeans(expression.matrix) > 0)]
    gene.sd <- rownames(expression.matrix)[which(apply(expression.matrix, 1, sd) > 0)]
    gene.list <- intersect(intersect(top.genes, mean.gene.expression), gene.sd)
    expression.matrix <- expression.matrix[gene.list, ]
    expression.matrix <- round(expression.matrix + 1)

    print("Chunking matrix...")
    # Check how many genes are present, before determining chunk size.
    if (nrow(expression.matrix) > 1000){
      chunk.size <- nrow(expression.matrix)/1000      
    } else if (nrow(expression.matrix) < 100){
      chunk.size <- nrow(expression.matrix)/10
    } else{
      chunk.size <- nrow(expression.matrix)/100
    }

    chunked.matrix <- ChunkMatrix(expression.matrix, axis = 0, chunks = chunk.size)
    return(chunked.matrix)
}


#' RunDiffExpression
#'
#' Compare the differential expression of genes between cells of different conditions.
#'
#' @param object A \linkS4class{EMSet} object that has undergone filtering and 
#' normalisation.
#' @param conditions Name of the column in the CellInformations lot where you have
#' defined the conditions you would like to test. eg cluster to compare clusters
#' identified by RunCORE.
#' @param condition.a Condition of the group you want to use as the baseline
#' @param condition.b Conditions of the group you want to compare to the baseline.
#' @param ngenes Perform differential expression analysis using top number of genes.
#' If omitted, this function will run analysis on ALL genes.
#' @param fitType Method used to fit a dispersion-mean relation by \pkg{DESeq}. 
#' Options: parametric, local (Default)
#' @param method Method used by \pkg{DESeq} to compute emperical dispersion.
#' Options: pooled, pooled-CR, per-condition (Default), blind 
#' @export
#'
RunDiffExpression <- function(object, conditions = NULL, condition.a = NULL, 
                              condition.b = NULL, fitType = c("parametric", "local"), 
                              method = c("pooled", "pooled-CR", "per-condition", "blind"),
                              ngenes = NULL) {
  # Object check
  if (class(object) != "EMSet") {
    stop("Please supply a EMSet object.")
  }
  
  # If user wants to compare clusters but hasn't run it
  if ((conditions == "cluster") && (is.null(object@CellInformation[, "cluster"]))) {
    stop("Please run the RunCORE function on this object before using this function.")
  }
  
  # Check for missing variables 
  if (missing(conditions) | missing(condition.a) | missing(condition.b)) {
    stop("Please supply your conditions and try again.")
  }
  
  # Check your conditions
  if (!(condition.a %in% object@CellInformation[, conditions])){
    stop("Please make sure Condition A is in your conditions column.")
  }
  
  if (length(condition.b) > 1){
    if (!(all(sapply(condition.b, function(x) x %in% object@CellInformation[, conditions])))){
      stop("Please make sure all conditions in Condition B are in your conditions column.")
    }    
  } else{
    if (!(condition.b %in% object@CellInformation[, conditions]) & condition.b != "Others"){
      stop("Please make sure Condition B is in your conditions column.")
    }
  }
  
  # Check ngenes
  if (!missing(ngenes) & !is.null(ngenes)){
    if (!is.numeric(ngenes)){
      stop("Please ensure ngenes argument is a number.")
    } 
  }
  
  # Use default values for DESeq if user hasn't defined them.
  if (missing(fitType)){
    fitType <- "local"
  }
  if (missing(method)){
    method <- "per-condition"
  }
  if (missing(ngenes)){
    ngenes <- NULL
  }
  
  # Prepare conditions for input into DESeq
  cell.info <- GetCellInfo(object)
  
  # Get Condition A information
  condition.a.df <- cell.info[which(cell.info[, conditions] == condition.a), ]
  
  # Get Condition B information
  if (condition.b != "Others"){
    condition.b.df <- cell.info[which(cell.info[ ,conditions] == condition.b), ]
  } else{
    condition.b.df <- cell.info[which(cell.info[ ,conditions] != condition.a), ]
  }
  
  cells <- c(as.vector(condition.a.df[ ,1]), as.vector(condition.b.df[ ,1]))
  condition.a.list <- as.character(condition.a.df[, conditions])
  condition.b.list <- as.character(rep(condition.b, nrow(condition.b.df)))
  condition.list <- c(condition.a.list, condition.b.list)
  condition.list <- as.factor(condition.list)
  
  # Prepare chunked matrix
  chunked.matrix <- PrepareCountData(object, cells, ngenes)
  
  print("Running DESeq...")    
  result.list <- BiocParallel::bplapply(chunked.matrix, RunDESeq, 
                                        condition.list = condition.list, 
                                        condition.a = condition.a, 
                                        condition.b = condition.b, 
                                        fitType = fitType,
                                        method = method)
  
  print("Differential expression complete!")
  
  print("Combining DE results...")
  output <- ProcessDEResults(result.list)
  return(output)
}