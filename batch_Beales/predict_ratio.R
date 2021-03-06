#' @title predict_ratio
#' @description Stratified Beale ratio estimator adapted from predict_ratio 
#'   module in FLUXMASTER. Requires functions mod, altmod, nsamp, and 
#'   collapse_stratbins. Input dataset should include data from exactly one 
#'   site.
#' @param siteQ data.frame containing date, Q, (other columns can exist)
#' @param siteConstit data.frame containing date, constitName, status (other
#'   columns can exist)
#' @param minDaysPerYear minumim number of days indicating the year is full
#' @param waterYear TRUE or FALSE
#' @param qName character indicating name of column with flow data
#' @param constitName character indicating name of column with WQ?s data
#' @param hi_flow_percentile number indicating threshold for designating 
#'   high-flow observations
#' @param ratio_strata_nsamp_threshold number indicating minimum number of 
#'   observations required for includsion of stratum in the ratio estimate
#' @param concTrans constant transformation factor for converting to units of 
#'   mg/L
#' @param qTrans constant transformation factor for converting Q to units of 
#'   ft3/s
#' @import dplyr for full_join, group_by, summarize, arrange
#' @import lubridate for year()
#' @import smwrBase for seasons()
#' @return data.frame with station, Beale avg flux (kg/y), SE Beale avg flux 
#'   (kg/y), number of strata for Beale avg flux
predict_ratio<-function(siteQ,siteConstit,minDaysPerYear,waterYear,dateName,qName,constitName,#stationIdname,
                        hi_flow_percentile,ratio_strata_nsamp_threshold,concTrans, qTrans){
  
  # rename for simplicity
  siteQ$date <- siteQ[[dateName]]
  siteQ$Q <- siteQ[[qName]]
  siteConstit$date <- siteConstit[[dateName]]
  siteConstit$Q <- siteConstit[[qName]]
  siteConstit$constit <- siteConstit[[constitName]]
  
  # merge data so that ratio_predict includes conc observations on dates when those are available
  ratio_predict <- full_join(siteQ[c('date','Q')],siteConstit[c('date','Q','constit')],by=c('date','Q')) %>%
    group_by(date) %>%
    summarize(
      Q = if(length(Q) > 1) Q[which(!is.na(constit))[1]] else Q,
      constit = if(length(constit) > 1) constit[which(!is.na(constit))[1]] else constit
    ) %>%
    arrange(date)
  
  # get transformation factors
  qTrans<-ifelse(is.na(qTrans),1,qTrans) # why not just make the default be 1 in the function formals?
  concTrans<-ifelse(is.na(concTrans),1,concTrans) # why not just make the default be 1 in the function formals?
  
  # set variables
  ifsamp<-ifelse(!is.na(ratio_predict$constit),1,0)
  dload<-ratio_predict$constit*concTrans*ratio_predict$Q*qTrans*2.4465024  #kg/day, if goal is to have Q in m3/s change 2.44 to 86.40 and qTrans takes Q into m3/s
  dflow<-ratio_predict$Q
  season<-as.numeric(smwrBase::seasons(ratio_predict$date,breaks= c("February","May","August","November"),Names=c(1,2,3,4)))
  
  # find high flow percentile
  dflow_hi<-as.numeric(quantile(dflow,probs=hi_flow_percentile/100))
  ifhi<-ifelse(dflow>=dflow_hi,1,0)
  
  # get number of missing flows per year
  if (waterYear==FALSE){
    ratio_predict$year<-lubridate::year(ratio_predict$date) 
  }else{
    ratio_predict$year<-ifelse(lubridate::month(ratio_predict$date)<10,lubridate::year(ratio_predict$date),lubridate::year(ratio_predict$date)+1)
  }
  
  # set if_avpredict variable
  existQ<-ratio_predict[which(!is.na(ratio_predict$Q)),]
  existQ<-aggregate(existQ[c("date")],by=list(year = existQ$year),length)
  names(existQ)[2]<-"countDays"
  ratio_predict<-merge(ratio_predict,existQ,all.x=TRUE,by="year")
  if_avpredict<-ifelse(ratio_predict$countDays>=minDaysPerYear,1,0)
  
  # predict_ratio started at line 184 (of original SAS code?)
  locsamp <- which(ifsamp!=0)  # Note, assumed locsamp = 1 is contained in locmon = 1 which is contained in locpred = 1. */
  ndates <- length(ratio_predict$date) 
  strat_nsamp_threshld <- min(ratio_strata_nsamp_threshold,sum(ifsamp)) 
  
  stratbin <- 2 * season + ifhi - 1 ;
  lochi_samp <- which(ifhi[locsamp]!=0) 
  nhi_samp <- length(lochi_samp) 
  nlo_samp <- length(locsamp) - nhi_samp 
  
  # Collapse all strata if total sample size is at or below threshold, else
  # collapse flow-based strata if either number of high flow or low flow
  # samples is less than threshold.
  if (nhi_samp + nlo_samp <= strat_nsamp_threshld){
    stratbin <- rep(1,length(stratbin)) 
  }else if (nhi_samp < strat_nsamp_threshld){
    stratbin <- stratbin - ifhi 
  }else if (nlo_samp < strat_nsamp_threshld){
    stratbin <- stratbin + 1 - ifhi 
  }
  
  # Collapse of strata across seasons
  lochi<-which(mod(stratbin,2)==0)
  loclo<-which(mod(stratbin,2) == 1) 
  
  if (length(lochi) > 0){ 
    stratbins <- unique(stratbin[lochi])
    strat_nsamp<-nsamp(stratbin,ifhi,ifsamp,stratbins,0)
    while(min(strat_nsamp) < strat_nsamp_threshld){ 
      collapse_stratbins(stratbin,strat_nsamp,stratbins)
    }
  }
  
  if (length(loclo) > 0){
    stratbins <- unique(stratbin[loclo])
    strat_nsamp <-nsamp(stratbin,ifhi,ifsamp,stratbins,1)
    while(min(strat_nsamp) < strat_nsamp_threshld){
      collapse_stratbins(stratbin,strat_nsamp,stratbins)
    }
  }
  
  stratbins <- unique(stratbin) 
  strata<-matrix(0,ncol=0,nrow=length(stratbin))
  for (s in stratbins){
    strat<-ifelse(stratbin==s,1,0)
    strata<-cbind(strata,strat)
  }
  
  strata_samp <- strata[locsamp,] 
  strat_nsamp <- colSums(strata_samp)
  min_strat_nsamp <- min(strat_nsamp)
  
  # Compute strata statistics
  dflowsum_strata <- t(dflow) %*% strata
  y_samp <- dload[locsamp] 
  x_samp <- dflow[locsamp] 
  ybar_samp <- t(y_samp) %*% strata_samp / as.vector(strat_nsamp)
  xbar_samp <- t(x_samp) %*% strata_samp / (as.vector(strat_nsamp))
  ybar_samp2 <- ybar_samp^2 
  xbar_samp2 <- xbar_samp^2 
  
  dy <- y_samp * strata_samp -  sweep(strata_samp,MARGIN=2,ybar_samp,`*`)
  dx <- x_samp * strata_samp - sweep(strata_samp,xbar_samp,MARGIN=2,`*`)
  dy2 <- dy ^ 2 
  dx2 <- dx ^ 2 
  ratio <- ybar_samp / xbar_samp 
  k2 <- 1 / (strat_nsamp - 1)
  cyy <- colSums(dy2) * k2 / ybar_samp2 
  cxx <- colSums(dx2) * k2 / xbar_samp2 
  cxy <- colSums(dy * dx) * k2 / (ybar_samp * xbar_samp) 
  k3 <- strat_nsamp / ((strat_nsamp - 1) * (strat_nsamp - 2)) 
  cxxx <- colSums(dx ^ 3) * k3 / (xbar_samp ^ 3) 
  cxxy <- colSums(dx2 * dy) * k3 / (xbar_samp2 * ybar_samp) 
  cxyy <- colSums(dx * dy2) * k3 / (xbar_samp * ybar_samp2) 
  nstrata <- colSums(strata) 
  fpc <- 1 - strat_nsamp / nstrata 
  theta <- fpc / strat_nsamp 
  
  # Compute the Beale bias-adjusted (to order O(n^-2)) ratio for each stratum
  # (Cochran eq. 6.83)
  adj_ratio <- ratio * (1 + theta * cxy) / (1 + theta * cxx) 
  
  # Compute the variance of the ratio (to order O(n^-2)) for each stratum
  # (denominator uses xbar_samp rather than xbar)(Tin, 1965, eq. 8 (V(t2))).
  # Convert to standard error. */
  v_ratio <- (ratio ^ 2) * (theta * (
    (cxx + cyy - 2 * cxy) +
      theta * (2 * (cxx ^ 2) + (cxy ^ 2) + (cxx * cyy) - 4 * (cxx * cxy)) +
      (2 / nstrata) * (cxxx + cxyy - 2 * cxxy) 
  )) 
  
  # Compute mean annual load and standard error mean annual load for the ratio estimator
  locav = which(if_avpredict!=0)
  if (length(locav) != 0){
    nyears <- round(length(locav) / 365.25) 
    sumflowbin <- colSums(strata[locav,] * dflow[locav]) / nyears 
    rload <- sum(sumflowbin * adj_ratio )
    serload <- sqrt(sum((sumflowbin ^ 2) * v_ratio) )
    nstrata <- length(stratbins) 
  }else{
    rload<-NA
    serload <-NA
    nstrata <- NA 
  }
  
  # # Visualize
  # library(ggplot2)
  # ratio_predict$stratbin <- factor(stratbin)
  # j <- 1
  # stratgroup <- c(j, rep(NA, length(stratbin)-1))
  # stratdiffs <- diff(stratbin)
  # for(i in seq_along(stratdiffs)) {
  #   if(stratdiffs[i] != 0) j <- j + 1
  #   stratgroup[i+1] <- j
  # }
  # ratio_predict$stratgroup <- stratgroup
  # ratio_predict$if_avpredict <- if_avpredict
  # ratio_predict$adj_ratio <- adj_ratio[as.character(ratio_predict$stratbin)]
  # ratio_predict$Lobs <- dload
  # ratio_predict$Lest <- ratio_predict$Q * ratio_predict$adj_ratio
  # ratio_subset <- ratio_predict[ratio_predict$date >= as.Date('2003-10-01') & ratio_predict$date < as.Date('2006-10-01'), ]
  # ggplot(ratio_subset, aes(x=date, color=stratbin, group=stratgroup)) + geom_line(aes(y=Lest/Q, group=NA), color='grey95') +
  #   geom_line(aes(y=Lest/Q), size=1) + geom_point(aes(y=Lobs/Q)) + theme_bw() + ylab(expression(C[est])) + xlab('')
  # ggsave('BREconcs.png', width=10, height=2)
  # ggplot(ratio_subset, aes(x=date, color=stratbin, group=stratgroup)) + geom_line(aes(y=Lest, group=NA), color='grey95') +
  #   geom_line(aes(y=Lest)) + geom_point(aes(y=Lobs)) + theme_bw() + ylab(expression(L[est])) + xlab('')
  # ggsave('BREfluxes.png', width=10, height=2)
  
  # Return
  ratio_load_param<-data.frame(rload,serload,nstrata) 
  names(ratio_load_param)[1:2]<-paste(names(ratio_load_param)[1:2],"_kg_y",sep="")
  return(ratio_load_param)
}
