require(rstan)

trainModel <- function(regulatorSpots, genesSpots, normalizedData, num_integration_points, ...)
{
  regulatorIndices = rowIDsFromSpotNames(normalizedData, regulatorSpots);
  genesIndices = rowIDsFromSpotNames(normalizedData, genesSpots);
  
  interactionMatrix = array(1,c(length(regulatorIndices),length(genesIndices)));
  
  numTime = length(normalizedData$times)
  numReplicates = length(normalizedData$experiments)
  
  numRegulators = length(regulatorIndices);
  numGenes = length(genesIndices);
  
  numDetailedTime = (numTime - 1) * num_integration_points + 1;
  logTfProfiles = array(0, c(numReplicates, numDetailedTime, 1));
  for(rep in 1:numReplicates){
    for(time in 1:numDetailedTime)
    {
      logTfProfiles[rep,time, 1] = log(normalizedData$trueProtein[rep, time]);
    }
  }
  
  modelData = list(num_time = numTime, 
                   num_integration_points = num_integration_points, 
                   num_regulators = numRegulators, 
                   num_replicates = numReplicates,
                   num_genes = numGenes, 
                   log_tf_profiles = logTfProfiles,
                   protein_degradation = array(normalizedData$proteinDegradation, c(1)),
                   protein_initial_level = array(normalizedData$trueProtein[,1], c(3,1)),
                   gene_profiles_observed = array(normalizedData$y[, genesIndices ,], c(numReplicates, numGenes,  numTime)), 
                   gene_profiles_sigma = array(sqrt(normalizedData$yvar[,genesIndices, ]), c(numReplicates, numGenes,  numTime)), 
                   interaction_matrix = interactionMatrix
  );
  return(stan('training.stan', data = modelData, ...));
}

plotTrainingFitGraphics <- function(samplesToPlot, trueProtein, trueRNA, rnaSigma,numTime, sampleTime, title){
  matplot(sampleTime, t(samplesToPlot), type="l", main = title) 
  points(1:numTime - 0.1, trueRNA, pch=1, col = "lightblue");
  arrows(1:numTime - 0.1, trueRNA - rnaSigma, 1:numTime - 0.1,trueRNA + rnaSigma ,length=0.05, angle=90, code=3, col = "lightblue")
  points(sampleTime, trueProtein, pch=19);
  
}

plotTrainingFit <- function(prediction, data, replicate, tfIndex, numSamples = 20, title = "", useODE = FALSE) {
  trueProtein = data$trueProtein[replicate,];
  trueRNA = data$y[replicate,1,];
  rnaSigma = data$yvar[replicate,1,];

  samples = extract(prediction,pars=c("log_tf_profiles","protein_initial_level"));
  true_value = samples$log_tf_profiles[,replicate,,tfIndex]
  
  numDetailedTime = length(trueProtein);
  numTime = length(trueRNA);
  
  detailedTime = ((1:numDetailedTime) - 1) * (numTime / (numDetailedTime + 1)) + 1;
  
  sampleIndices = sample(1:(dim(true_value)[1]),numSamples);
  
  
  samplesToPlot = exp(true_value[sampleIndices,]);
  if(numDetailedTime == dim(samplesToPlot)[2])
  {
    sampleTime = detailedTime
  }
  else
  {
    sampleTime = 1:numTime
  }

  if(useODE)
  {
    odeResults = array(0, c(numSamples, numDetailedTime));
    for(sample in 1:length(sampleIndices)){
      sampleIndex = sampleIndices[sample];
      rnaProfile = data$trueRegulator[replicate, ];
      proteinODEParams = c(degradation = data$proteinDegradation, regulator = approxfun(detailedTime, rnaProfile, rule=2));  
      
      odeResults[sample,] = ode( y = c(x = samples$protein_initial_level[sampleIndex,replicate,tfIndex]), times = detailedTime, func = proteinODE, parms = proteinODEParams, method = "ode45")[,"x"];
      
    }
    plotTrainingFitGraphics(odeResults, trueProtein, trueRNA, rnaSigma,numTime, sampleTime, paste0(title," - ODE"));  
  }
    
  plotTrainingFitGraphics(samplesToPlot, trueProtein, trueRNA, rnaSigma,numTime, sampleTime, title)  
}

plotTrainingTargetFit <- function(prediction, data, targetIndex, replicate, numSamples = 20, title = "", useODE = TRUE, dataIndex = targetIndex)
{
  observedTarget = data$y[replicate,dataIndex + 1,]  
  targetSigma = data$yvar[replicate,dataIndex + 1,]  
  trueTarget = data$trueTargets[replicate,dataIndex,]  
  
  samples = extract(prediction,pars=c("gene_profiles_true","initial_condition","basal_transcription","degradation","transcription_sensitivity","interaction_bias","interaction_weights"))
  sampleIndices = sample(1:(dim(samples$initial_condition)[1]),numSamples);
  
  #protein_profiles = exp(samples$log_tf_profiles[sampleIndices,replicate,,])
  
  numTime = length(trueTarget);
  numDetailedTime = (numTime - 1) * data$numIntegrationPoints + 1;
  
  detailedTime = ((1:numDetailedTime) - 1) * (numTime / (numDetailedTime + 1)) + 1;
  
  if(useODE) {
    #solve the ODE to get the actual profiles of interest
    integrated_profile = array(-1, c(numSamples,numTime));   
    
    for(sample in 1:numSamples) {
      sampleId = sampleIndices[sample];
      params = c(degradation = samples$degradation[sampleId,targetIndex], bias = samples$interaction_bias[sampleId,targetIndex], sensitivity = samples$transcription_sensitivity[sampleId,targetIndex], basalTranscription = samples$basal_transcription[sampleId,targetIndex], weight = samples$interaction_weights[sampleId,targetIndex,1],  protein = approxfun(detailedTime, data$trueProtein[replicate,], rule=2));

      integrated_profile[sample,] = ode( y = c(x = samples$initial_condition[sampleId,replicate, targetIndex]), times = 1:numTime, func = targetODE, parms = params, method = "ode45")[,"x"];
    }
    plotPredictFitGraphics(integrated_profile, observedTarget, trueTarget, targetSigma, numTime, paste0(title, " - R ODE"))
    
    # for(sample in 1:numSamples) {
    #    sampleId = sampleIndices[sample];
    #    integrated_profile[sample,] = numericalIntegration(
    #      initialCondition = samples$initial_condition[sampleId,replicate, targetIndex],
    #      degradation = samples$degradation[sampleId, targetIndex],
    #      bias = samples$interaction_bias[sampleId, targetIndex],
    #      sensitivity = samples$transcription_sensitivity[sampleId, targetIndex],
    #      basalTranscription = samples$basal_transcription[sampleId, targetIndex],
    #      weight = samples$interaction_weights[sampleId, targetIndex, 1],
    #      protein = protein_profiles[sample,],
    #      numTime = numTime,
    #      numIntegrationPoints = data$numIntegrationPoints)
    #  }
    #  plotPredictFitGraphics(integrated_profile, observedTarget, trueTarget, targetSigma, numTime, paste0(title, " - R Numeric"))
  }
  
  samplesToPlot = samples$gene_profiles_true[sampleIndices,replicate,targetIndex,];
  plotPredictFitGraphics(samplesToPlot, observedTarget, trueTarget, targetSigma, numTime, title)

}

plotAllTargetFits <- function(prediction, simulatedData, simulatedDataIndices = 1:length(simulatedData$targetSpots), useODE = FALSE)
{
  for(target in 1:length(simulatedDataIndices)){
    for(replicate in 1:length(simulatedData$experiments)){
      simulatedIndex = simulatedDataIndices[target]
      plotTrainingTargetFit(prediction,simulatedData, target, replicate, title = paste0("Target ", simulatedIndex,"-",replicate), useODE = useODE, dataIndex = simulatedIndex)
    }
  }
  
}

plotRegulatorFit <- function(prediction, data, replicate = 1, tfIndex = 1, numSamples = 20, title = replicate) 
{
  true_value = extract(prediction,pars="regulator_profiles_true")$regulator_profiles_true[,replicate,tfIndex,]
  
  numDetailedTime = dim(true_value)[2];
  numTime = length(data$times);
  
  detailedTime = ((1:numDetailedTime) - 1) * (numTime / (numDetailedTime + 1)) + 1;
  
  samplesToPlot = true_value[sample(1:(dim(true_value)[1]),numSamples),];
  
  matplot(detailedTime, t(samplesToPlot), type="l", main = title) 
  values = data$y[replicate,tfIndex,];
  sigma = data$yvar[replicate,tfIndex,];
  points(1:numTime - 0.1, values, pch=19);
  arrows(1:numTime - 0.1, values - sigma, 1:numTime - 0.1,values + sigma ,length=0.05, angle=90, code=3)
  #points(detailedTime, trueProtein, pch=19);
}

testTraining <- function(simulatedData = NULL,numIntegrationPoints = 10, numTargets = 10, targetIndices = NULL, ...) {
  if(is.null(simulatedData))
  {
    simulatedData = simulateData(c(0.8,0.7,0.2,0.3,0.6,1.5,2.7,0.9,0.8,0.6,0.2,1.6), numIntegrationPoints, numTargets = numTargets)
  }

  if(is.null(targetIndices)){
    targetSpots = simulatedData$targetSpots
  }
  else {
    targetSpots = simulatedData$targetSpots[targetIndices];
  }
    
  trainResult = trainModel(simulatedData$regulatorSpots, targetSpots, simulatedData, numIntegrationPoints, ...);
  
  tryCatch({
    if(is.null(targetIndices)){
      plotAllTargetFits(trainResult, simulatedData);
    }
    else {
      plotAllTargetFits(trainResult, simulatedData, simulatedDataIndices = targetIndices);
    }
    # for(replicate in 1:length(simulatedData$experiments)){
    #   plotTrainingFit(trainResult, simulatedData, replicate,1, title = replicate, useODE = FALSE);
    # }
  }, error = function(e) {
    print(e);
  });
  
  
  return(list(fit = trainResult, data = simulatedData));
}