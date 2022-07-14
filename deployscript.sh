

#Install Basic Utilities
yes | sudo apt install git curl make

#Install the openstack-helm repos
cd /opt/
git clone https://opendev.org/openstack/openstack-helm-infra.git
git clone https://opendev.org/openstack/openstack-helm.git

#Install docker 
yes | sudo apt install docker.io

#Install kubeadm 
sudo apt-get update
yes | sudo apt-get install -y apt-transport-https ca-certificates curl

sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

#Install helm
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

#Deploy Kubernetes and Helm
cd /opt/openstack-helm
./tools/deployment/developer/common/010-deploy-k8s.sh

#namespaceStatus2=$(kubectl get nodes node-role.kubernetes.io/control-plane- node-role.kubernetes.io/master- -o json | jq .status.phase -r)
#while [ $namespaceStatus2 != "Ready" ]
#do
#  ./tools/deployment/developer/common/010-deploy-k8s.sh
#done

sudo -H -E pip3 install --upgrade pip
sudo -H -E pip3 install \
  -c${UPPER_CONSTRAINTS_FILE:=https://releases.openstack.org/constraints/upper/${OPENSTACK_RELEASE:-xena}} \
  cmd2 python-openstackclient python-heatclient --ignore-installed

export HELM_CHART_ROOT_PATH=/opt/openstack-helm-infra/
export OSH_INFRA_ROOT_PATH=/opt/openstack-helm-infra/

sudo -H mkdir -p /etc/openstack
sudo -H chown -R $(id -un): /etc/openstack
FEATURE_GATE="tls"; if [[ ${FEATURE_GATES//,/ } =~ (^|[[:space:]])${FEATURE_GATE}($|[[:space:]]) ]]; then
  tee /etc/openstack/clouds.yaml << EOF
  clouds:
    openstack_helm:
      region_name: RegionOne
      identity_api_version: 3
      cacert: /etc/openstack-helm/certs/ca/ca.pem
      auth:
        username: 'admin'
        password: 'password'
        project_name: 'admin'
        project_domain_name: 'default'
        user_domain_name: 'default'
        auth_url: 'https://keystone.openstack.svc.cluster.local/v3'
EOF
else
  tee /etc/openstack/clouds.yaml << EOF
  clouds:
    openstack_helm:
      region_name: RegionOne
      identity_api_version: 3
      auth:
        username: 'admin'
        password: 'password'
        project_name: 'admin'
        project_domain_name: 'default'
        user_domain_name: 'default'
        auth_url: 'http://keystone.openstack.svc.cluster.local/v3'
EOF
fi


#Build Helm-toolkit,most charts depend on it
make -C ${HELM_CHART_ROOT_PATH} helm-toolkit


#Deploy the ingress controller
make -C ${HELM_CHART_ROOT_PATH} ingress

: ${OSH_EXTRA_HELM_ARGS:=""}
tee /tmp/ingress-kube-system.yaml << EOF
deployment:
  mode: cluster
  type: DaemonSet
network:
  host_namespace: true
EOF


touch /tmp/ingress-component.yaml

if [ -n "${OSH_DEPLOY_MULTINODE}" ]; then
  tee --append /tmp/ingress-kube-system.yaml << EOF
pod:
  replicas:
    error_page: 2
EOF

  tee /tmp/ingress-component.yaml << EOF
pod:
  replicas:
    ingress: 2
    error_page: 2
EOF
fi


namespaceStatus=$(kubectl get ns openstack -o json | jq .status.phase -r)
if [ $namespaceStatus != "Active" ]
then
   sudo kubectl create ns openstack

namespaceStatus1=$(kubectl get ns ceph -o json | jq .status.phase -r)
if [ $namespaceStatus1 != "Active" ]
then
   sudo kubectl create ns ceph
   
helm upgrade --install ingress-kube-system ${HELM_CHART_ROOT_PATH}/ingress \
  --namespace=kube-system \
  --values=/tmp/ingress-kube-system.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS_KUBE_SYSTEM}
  
helm upgrade --install ingress-openstack ${HELM_CHART_ROOT_PATH}/ingress \
  --namespace=openstack \
  --values=/tmp/ingress-component.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS_OPENSTACK}

helm upgrade --install ingress-ceph ${HELM_CHART_ROOT_PATH}/ingress \
  --namespace=ceph \
  --values=/tmp/ingress-component.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS} \
  ${OSH_EXTRA_HELM_ARGS_INGRESS_CEPH}

#Deploy ceph
export CEPH_ENABLED=true

if [ "${CREATE_LOOPBACK_DEVICES_FOR_CEPH:=true}" == "true" ]; then
  ./tools/deployment/common/setup-ceph-loopback-device.sh --ceph-osd-data ${CEPH_OSD_DATA_DEVICE:=/dev/loop20} \
  --ceph-osd-dbwal ${CEPH_OSD_DB_WAL_DEVICE:=/dev/loop21}
fi

export HELM_CHART_ROOT_PATH="${HELM_CHART_ROOT_PATH:="${OSH_INFRA_PATH:="../openstack-helm-infra"}"}"
for CHART in ceph-mon ceph-osd ceph-client ceph-provisioners; do
  make -C ${HELM_CHART_ROOT_PATH} "${CHART}"
done

[ -s /tmp/ceph-fs-uuid.txt ] || uuidgen > /tmp/ceph-fs-uuid.txt
CEPH_FS_ID="$(cat /tmp/ceph-fs-uuid.txt)"

. /etc/os-release
if [ "x${ID}" == "xcentos" ] || \
   ([ "x${ID}" == "xubuntu" ] && \
   dpkg --compare-versions "$(uname -r)" "lt" "4.5"); then
  CRUSH_TUNABLES=hammer
else
  CRUSH_TUNABLES=null
fi
tee /tmp/ceph.yaml <<EOF
endpoints:
  ceph_mon:
    namespace: ceph
  ceph_mgr:
    namespace: ceph
network:
  public: 172.17.0.1/16
  cluster: 172.17.0.1/16
deployment:
  storage_secrets: true
  ceph: true
  rbd_provisioner: true
  csi_rbd_provisioner: true
  cephfs_provisioner: true
  client_secrets: false
manifests:
  deployment_rbd_provisioner: true
  deployment_csi_rbd_provisioner: true
  deployment_cephfs_provisioner: true
bootstrap:
  enabled: true
conf:
  ceph:
    global:
      fsid: ${CEPH_FS_ID}
      mon_addr: :6789
      osd_pool_default_size: 1
    osd:
      osd_crush_chooseleaf_type: 0
  pool:
    crush:
      tunables: ${CRUSH_TUNABLES}
    target:
      osd: 1
      pg_per_osd: 100
    default:
      crush_rule: same_host
    spec:
      # Health metrics pool
      - name: device_health_metrics
        application: mgr_devicehealth
        replication: 1
        percent_total_data: 5
      # RBD pool
      - name: rbd
        application: rbd
        replication: 1
        percent_total_data: 40
      # CephFS pools
      - name: cephfs_metadata
        application: cephfs
        replication: 1
        percent_total_data: 5
      - name: cephfs_data
        application: cephfs
        replication: 1
        percent_total_data: 10
      # RadosGW pools
      - name: .rgw.root
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.control
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.data.root
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.gc
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.log
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.intent-log
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.meta
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.usage
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.users.keys
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.users.email
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.users.swift
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.users.uid
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.buckets.extra
        application: rgw
        replication: 1
        percent_total_data: 0.1
      - name: default.rgw.buckets.index
        application: rgw
        replication: 1
        percent_total_data: 3
      - name: default.rgw.buckets.data
        application: rgw
        replication: 1
        percent_total_data: 34.8
  storage:
    osd:
      - data:
          type: bluestore
          location: ${CEPH_OSD_DATA_DEVICE}
        block_db:
          location: ${CEPH_OSD_DB_WAL_DEVICE}
          size: "5GB"
        block_wal:
          location: ${CEPH_OSD_DB_WAL_DEVICE}
          size: "2GB"

pod:
  replicas:
    mds: 1
    mgr: 1

EOF

tee start.sh<<EOF
for CHART in ceph-mon ceph-osd ceph-client ceph-provisioners; do

  helm upgrade --install ${CHART} ${HELM_CHART_ROOT_PATH}/${CHART} \
    --namespace=ceph \
    --values=/tmp/ceph.yaml \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_CEPH:-$(./tools/deployment/common/get-values-overrides.sh ${CHART})}

  #NOTE: Wait for deploy
  ./tools/deployment/common/wait-for-pods.sh ceph

  #NOTE: Validate deploy
  MON_POD=$(kubectl get pods \
    --namespace=ceph \
    --selector="application=ceph" \
    --selector="component=mon" \
    --no-headers | awk '{ print $1; exit }')
  kubectl exec -n ceph ${MON_POD} -- ceph -s
done
EOF

chmod 777 start.sh
./start.sh

#Activate the openstack namespace to use ceph
make -C ${HELM_CHART_ROOT_PATH} ceph-provisioners

: ${OSH_EXTRA_HELM_ARGS:=""}
tee /tmp/ceph-openstack-config.yaml <<EOF
endpoints:
  ceph_mon:
    namespace: ceph
network:
  public: 172.17.0.1/16
  cluster: 172.17.0.1/16
deployment:
  ceph: false
  rbd_provisioner: false
  cephfs_provisioner: false
  csi_rbd_provisioner: false
  client_secrets: true
bootstrap:
  enabled: false
EOF

helm upgrade --install ceph-openstack-config ${HELM_CHART_ROOT_PATH}/ceph-provisioners \
  --namespace=openstack \
  --values=/tmp/ceph-openstack-config.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_CEPH_NS_ACTIVATE}
  
#Deploy mariadb

make -C ${HELM_CHART_ROOT_PATH} mariadb

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install mariadb ${HELM_CHART_ROOT_PATH}/mariadb \
    --namespace=openstack \
    --set pod.replicas.server=1 \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_MARIADB}

#Deploy rabbitmq

make -C ${HELM_CHART_ROOT_PATH} rabbitmq

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install rabbitmq ${HELM_CHART_ROOT_PATH}/rabbitmq \
    --namespace=openstack \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_RABBITMQ}
    
    
#Deploy Memcached
make -C ${HELM_CHART_ROOT_PATH} memcached

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install memcached ${HELM_CHART_ROOT_PATH}/memcached \
    --namespace=openstack \
    ${OSH_EXTRA_HELM_ARGS:=} \
    ${OSH_EXTRA_HELM_ARGS_MEMCACHED}

#Deploy keystone
make keystone

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install keystone ./keystone \
    --namespace=openstack \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_KEYSTONE}

#Deploy horizon
make horizon

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install horizon ./horizon \
    --namespace=openstack \
    --set network.node_port.enabled=true \
    --set network.node_port.port=31000 \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_HORIZON}
    
#Deploy rados for object storage

make -C ${HELM_CHART_ROOT_PATH} ceph-rgw
: ${OSH_EXTRA_HELM_ARGS:=""}
tee /tmp/radosgw-openstack.yaml <<EOF
endpoints:
  identity:
    namespace: openstack
  object_store:
    namespace: openstack
  ceph_mon:
    namespace: ceph
network:
  public: 172.17.0.1/16
  cluster: 172.17.0.1/16
deployment:
  ceph: true
bootstrap:
  enabled: false
conf:
  rgw_ks:
    enabled: true
pod:
  replicas:
    rgw: 1
EOF

helm upgrade --install radosgw-openstack ${HELM_CHART_ROOT_PATH}/ceph-rgw \
  --namespace=openstack \
  --values=/tmp/radosgw-openstack.yaml \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_CEPH_RGW}
  
#Deploy glance

make glance
: ${OSH_EXTRA_HELM_ARGS:=""}
: ${GLANCE_BACKEND:="swift"}
: ${OSH_EXTRA_HELM_ARGS_GLANCE:="$(./tools/deployment/common/get-values-overrides.sh glance)"}
tee /tmp/glance.yaml <<EOF
storage: ${GLANCE_BACKEND}
EOF
helm upgrade --install glance ./glance \
  --namespace=openstack \
  --values=/tmp/glance.yaml \
  --set manifests.network_policy=true \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_GLANCE}
  
#Deploy cinder
: ${OSH_EXTRA_HELM_ARGS:=""}
tee /tmp/cinder.yaml <<EOF
conf:
  ceph:
    pools:
      backup:
        replication: 1
        crush_rule: same_host
        chunk_size: 8
        app_name: cinder-backup
      cinder.volumes:
        replication: 1
        crush_rule: same_host
        chunk_size: 8
        app_name: cinder-volume
EOF

helm upgrade --install cinder ./cinder \
  --namespace=openstack \
  --values=/tmp/cinder.yaml \
    --set manifests.network_policy=true \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_CINDER}

#Deploy openvSwitch
make -C ${HELM_CHART_ROOT_PATH} openvswitch

: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install openvswitch ${HELM_CHART_ROOT_PATH}/openvswitch \
  --namespace=openstack \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_OPENVSWITCH}
  
#Deploy libvirt  
make -C ${HELM_CHART_ROOT_PATH} libvirt
: ${OSH_EXTRA_HELM_ARGS:=""}
helm upgrade --install libvirt ${HELM_CHART_ROOT_PATH}/libvirt \
  --namespace=openstack \
  ${OSH_EXTRA_HELM_ARGS} \
  ${OSH_EXTRA_HELM_ARGS_LIBVIRT}  
  

#Deploy compute Kit(Nova and Neutron)
./tools/deployment/developer/ceph/160-compute-kit.sh

#setup the gateway to the public network
./tools/deployment/developer/ceph/170-setup-gateway.sh

my_br_ip=$(ifconfig eth0 | egrep -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'  | cut -d' ' -f2)

echo use ssh -L 32020:$my_br_ip:31000 ubuntu@$my_br_ip for port forwarding







