#!/bin/bash

# Create appropriate directories under workspace
mkdir -p ./workspace/configs
rm -rf ./workspace/logs*

NODES=$((NUM_NODES + 0))

# 5 more nodes for solr cluster
ESTIMATED_NODES_1=$((NODES))
ESTIMATED_NODES_2=$((NODES + 1))

if [ "$LOADER_LOADTESTER" = true ] ; then
    cp ./scripts/src/loader_pods.yaml ./scripts/src/cluster.yaml
else
    cp ./scripts/src/load-tester_pods.yaml ./scripts/src/cluster.yaml
fi

CID=`docker container ls -aq -f "name=kubectl-support"`

# initialise the loader / load-tester image
sed -i "s/namespace_filler/${GCP_K8_CLUSTER_NAMESPACE}/" ./scripts/src/cluster.yaml
sed -i "s/num_replicas/${NODES}/" ./scripts/src/cluster.yaml
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
if [ "$LOADER_LOADTESTER" = true ] ; then
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

mkdir ./workspace/reports-${BUILD_NUMBER}/

if [ "$LOADER_LOADTESTER" = true ] ; then

    readarray -t NUM_DOCS_LINES <<< "${NUM_DOCS}"
    readarray -t ZK_HOST_LINES <<< "${ZK_HOST}"
    readarray -t COLLECTION_LINES <<< "${COLLECTION}"

    # run gatling test for a simulation and pass relevant params
    for (( c=0; c<${NODES}; c++ ))
    do
       docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} loader-${c} -- sh runLoader.sh ${NUM_DOCS_LINES[c]} ${ZK_HOST_LINES[c]} ${COLLECTION_LINES[c]}
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
        docker exec kubectl-support mkdir -p /opt/results/node-${c}
        docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/loader-${c}:/opt/loader/results.txt /opt/results/node-${c}/
    done

else

    readarray -t JDBC_QUERY_LINES <<< "${JDBC_QUERY}"
    readarray -t JDBC_SQL_HOST_LINES <<< "${JDBC_SQL_HOST}"
    readarray -t JDBC_USER_LINES <<< "${JDBC_USER}"
    readarray -t JDBC_PASSWORD_LINES <<< "${JDBC_PASSWORD}"
    readarray -t N_TIMES_LINES <<< "${N_TIMES}"

    # run gatling test for a simulation and pass relevant params
    for (( c=0; c<${NODES}; c++ ))
    do
       docker exec -d kubectl-support kubectl exec -n ${GCP_K8_CLUSTER_NAMESPACE} load-tester-${c} -- sh runJDBC.sh "${JDBC_QUERY_LINES[c]}" ${JDBC_SQL_HOST_LINES[c]} ${JDBC_USER_LINES[c]} ${JDBC_PASSWORD_LINES[c]} ${N_TIMES_LINES[c]}
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
        docker exec kubectl-support mkdir -p /opt/results/node-${c}
        docker exec kubectl-support kubectl cp ${GCP_K8_CLUSTER_NAMESPACE}/load-tester-${c}:/opt/load_tester/results.txt /opt/results/node-${c}/
    done

fi

# copy the perf tests to the workspace
docker cp ${CID}:/opt/results ./workspace/reports-${BUILD_NUMBER}/
docker exec kubectl-support rm -rf /opt/results/

for (( c=0; c<${NODES}; c++ ))
do
    echo "Last 100 lines from node ${c}"
    echo "---------------------------------------------"
    echo "---------------------------------------------"
    tail -n 100 ./workspace/reports-${BUILD_NUMBER}/results/node-${c}/results.txt
    echo "---------------------------------------------"
    echo "---------------------------------------------"
done

# delete loader / load-tester service and statefulsets, redundant step
if [ "$LOADER_LOADTESTER" = true ] ; then
    docker exec kubectl-support kubectl delete statefulsets loader --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "loader statefulsets not available!!"
    docker exec kubectl-support kubectl delete service loader --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "loader service not available!!"
else
    docker exec kubectl-support kubectl delete statefulsets load-tester --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "load-tester statefulsets not available!!"
    docker exec kubectl-support kubectl delete service load-tester --namespace=${GCP_K8_CLUSTER_NAMESPACE} || echo "load-tester service not available!!"
fi
sleep 10