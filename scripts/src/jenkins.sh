#!/bin/bash

# Create appropriate directories under workspace
mkdir -p ./workspace/configs

NODES=$((NUM_NODES + 0))

# 5 more nodes for solr cluster
ESTIMATED_NODES_1=$((NODES))
ESTIMATED_NODES_2=$((NODES + 1))

if [ "$LOADER" = true ] ; then
    cp ./scripts/src/loader_pods.yaml ./scripts/src/cluster.yaml
else
    cp ./scripts/src/load-tester_pods.yaml ./scripts/src/cluster.yaml
fi

CID=`docker container ls -aq -f "name=kubectl-support"`

# initialise the loader / load-tester image
sed -i "s/namespace_filler/${GCP_K8_CLUSTER_NAMESPACE}/" ./scripts/src/cluster.yaml
sed -i "s/num-replicas/${NODES}/" ./scripts/src/cluster.yaml
docker cp ./scripts/src/cluster.yaml ${CID}:/opt/cluster.yaml
# optional property files a user may have uploaded to jenkins
# Note: Jenkins uses the same string for the file name, and the ENV var,
# so we're requiring CLUSTER_YAML_FILE (instead of cluster.yaml) so bash can read the ENV var
if [ ! -z "${CLUSTER_YAML_FILE}" ]; then
  if  [ ! -f ./CLUSTER_YAML_FILE ]; then
    echo "Found ENV{CLUSTER_YAML_FILE}=${CLUSTER_YAML_FILE} -- but ./CLUSTER_YAML_FILE not found, jenkins bug?" && exit -1;
  fi
  echo "Copying user supplied cluster file to workspace/scripts/src/cluster.yaml"
  cp ./CLUSTER_YAML_FILE ./workspace/configs/${CLUSTER_YAML_FILE}

  # copy the configs from local to dockers
  docker cp ./workspace/configs/${CLUSTER_YAML_FILE} ${CID}:/opt/cluster.yaml
else
  rm -rf ./CLUSTER_YAML_FILE
fi

# delete loader / load-tester service and statefulsets, redundant step
if [ "$LOADER" = true ] ; then
    docker exec kubectl-support kubectl delete statefulsets loader --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "loader statefulsets not available!!"
    docker exec kubectl-support kubectl delete service loader --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "loader service not available!!"
else
    docker exec kubectl-support kubectl delete statefulsets load-tester --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "load-tester statefulsets not available!!"
    docker exec kubectl-support kubectl delete service load-tester --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "load-tester service not available!!"
fi
sleep 10

docker exec kubectl-support kubectl create -f /opt/cluster.yaml || echo "loader service already created!!"
# buffer sleep for 3 mins to get the pods ready, and then check
sleep 60

# wait until all pods comes up running
TOTAL_PODS=`docker exec kubectl-support kubectl get pods --all-namespaces | grep "load" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l`
# find better way to determine all pods running
while [ "${TOTAL_PODS}" != "${ESTIMATED_NODES_1}" -a "${TOTAL_PODS}" != "${ESTIMATED_NODES_2}" ]
do
   sleep 15
   TOTAL_PODS=`docker exec kubectl-support kubectl get pods --all-namespaces | grep "load" | grep "${GCP_K8_CLUSTER_NAMESPACE}" | grep "Running" | grep "1/1" | wc -l`
done

# execute the load test on docker
echo "JOB DESCRIPTION: running....."

if [ "$LOADER" = true ] ; then

    # create results directory on the docker
    for (( c=0; c<${NODES}; c++ ))
    do
      docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} loader-${c} -- mkdir -p /tmp/logs-${c}
    done

    # run gatling test for a simulation and pass relevant params
    for (( c=0; c<${NODES}; c++ ))
    do
      if [ "$PRINT_LOG" = true ] ; then
        docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} loader-${c} -- sh runLoader.sh ${NUM_DOCS} ${ZK_HOST} ${COLLECTION} >> loader.log &
      else
        docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} loader-${c} -- sh runLoader.sh ${NUM_DOCS} ${ZK_HOST} ${COLLECTION}
      fi
    done

    for (( c=0; c<${NODES}; c++ ))
    do
        IF_CMD_EXEC=`docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} loader-${c} -- ps | grep "java" | wc -l`
        while [ "${IF_CMD_EXEC}" != "0" ]
        do
            sleep 20
            IF_CMD_EXEC=`docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} loader-${c} -- ps | grep "java" | wc -l`
        done
    done

    # gather the logs
    for (( c=0; c<${NODES}; c++ ))
    do
        docker exec kubectl-support mkdir -p /opt/results/logs-${c}
        docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/loader-${c}:/tmp/logs-${c}/ /opt/results/logs-${c}/
    done

    # copy the perf tests to the workspace
    mkdir -p workspace/logs-${BUILD_NUMBER}/
    docker cp ${CID}:/opt/results ./workspace/reports-${BUILD_NUMBER}/
    docker exec kubectl-support rm -rf /opt/results/

else

    # create results directory on the docker
    for (( c=0; c<${NODES}; c++ ))
    do
      docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} load-tester-${c} -- mkdir -p /tmp/logs-${c}
    done

    # run gatling test for a simulation and pass relevant params
    for (( c=0; c<${NODES}; c++ ))
    do
      if [ "$PRINT_LOG" = true ] ; then
        docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} load-tester-${c} -- sh runJDBC.sh \"${JDBC_QUERY}\" ${JDBC_SQL_HOST} ${JDBC_USER} ${JDBC_PASSWORD} ${N_TIMES} >> load-tester.log &
      else
        docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} load-tester-${c} -- sh runJDBC.sh \"${JDBC_QUERY}\" ${JDBC_SQL_HOST} ${JDBC_USER} ${JDBC_PASSWORD} ${N_TIMES}
      fi
    done

    for (( c=0; c<${NODES}; c++ ))
    do
        IF_CMD_EXEC=`docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} load-tester-${c} -- ps | grep "java" | wc -l`
        while [ "${IF_CMD_EXEC}" != "0" ]
        do
            sleep 20
            IF_CMD_EXEC=`docker exec kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} load-tester-${c} -- ps | grep "java" | wc -l`
        done
    done

    # gather the logs
    for (( c=0; c<${NODES}; c++ ))
    do
        docker exec kubectl-support mkdir -p /opt/results/logs-${c}
        docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/load-tester-${c}:/tmp/logs-${c}/ /opt/results/logs-${c}/
    done

    # copy the perf tests to the workspace
    mkdir -p workspace/logs-${BUILD_NUMBER}/
    docker cp ${CID}:/opt/results ./workspace/reports-${BUILD_NUMBER}/
    docker exec kubectl-support rm -rf /opt/results/
fi

# delete loader / load-tester service and statefulsets, redundant step
if [ "$LOADER" = true ] ; then
    docker exec kubectl-support kubectl delete statefulsets loader --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "loader statefulsets not available!!"
    docker exec kubectl-support kubectl delete service loader --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "loader service not available!!"
else
    docker exec kubectl-support kubectl delete statefulsets load-tester --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "load-tester statefulsets not available!!"
    docker exec kubectl-support kubectl delete service load-tester --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "load-tester service not available!!"
fi
sleep 10