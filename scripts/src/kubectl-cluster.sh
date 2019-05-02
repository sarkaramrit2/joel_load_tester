#!/usr/bin/env bash

# Fail if no simulation class if specified
if [ -z "${GCP_KEY_FILE}" ]; then echo "GCP_KEY_FILE must be non-blank" && exit -1; fi

set -e
set -x

docker run -it -d --rm --name kubectl-support sarkaramrit2/kubectl-support:latest
# set container id in which the docker is running
CID=`docker container ls -aq -f "name=kubectl-support"`

if [ ! -z "${GCP_KEY_FILE}" ]; then
  if  [ ! -f ./GCP_KEY_FILE ]; then
    echo "Found ENV{GCP_KEY_FILE}=${GCP_KEY_FILE} -- but ./GCP_KEY_FILE not found, jenkins bug?" && exit -1;
  fi
  # copy the configs from local to docker
  docker cp ./GCP_KEY_FILE ${CID}:/opt/${GCP_KEY_FILE}
else
  rm -rf ./GCP_KEY_FILE
fi

# delete the GCP file
rm -rf ./GCP_KEY_FILE

docker exec kubectl-support gcloud auth activate-service-account --key-file /opt/${GCP_KEY_FILE}
docker exec kubectl-support gcloud config get-value core/account
docker exec kubectl-support gcloud config set project ${GCP_K8_PROJECT}
docker exec kubectl-support gcloud config list
if [ "$SET_ZONE_UNSET_REGION" = true ] ; then
    docker exec kubectl-support gcloud container clusters get-credentials ${GCP_K8_CLUSTER_NAME} --zone "$ZONE_REGION"
else
    docker exec kubectl-support gcloud container clusters get-credentials ${GCP_K8_CLUSTER_NAME} --region "$ZONE_REGION"
fi