#update and upgrading
sudo apt-get update
sudo apt-get -y upgrade

#Install docker 
yes | sudo apt install docker.io

#Install kubeadm for k8s cluster
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

#Install Basic Utilities
sudo apt install git curl make

#Clone the openstack-helm repos
cd /opt/
git clone https://opendev.org/openstack/openstack-helm-infra.git
git clone https://opendev.org/openstack/openstack-helm.git

#Deploy Kubernetes and helm 
./tools/deployment/developer/common/010-deploy-k8s.sh

#setup client on the host and assemble the charts
./tools/deployment/developer/common/020-setup-client.sh

#Deploy the ingress Controller
./tools/deployment/component/common/ingress.sh

#Deploy Ceph
./tools/deployment/developer/ceph/040-ceph.sh


#Activate the openstack namespace to be able to use Ceph 
./tools/deployment/developer/ceph/045-ceph-ns-activate.sh

#Deploy Mariadb
./tools/deployment/developer/ceph/050-mariadb.sh

#Deploy RabbitMQ
./tools/deployment/developer/ceph/060-rabbitmq.sh

#Deploy Memcached
./tools/deployment/developer/ceph/070-memcached.sh

#Deploy Keystone 
./tools/deployment/developer/ceph/080-keystone.sh

#Deploy Horizon
./tools/deployment/developer/ceph/100-horizon.sh

#Deploy Rados Gateway for object store
./tools/deployment/developer/ceph/110-ceph-radosgateway.sh

#Deploy Glance 
./tools/deployment/developer/ceph/120-glance.sh

#Deploy Cinder
./tools/deployment/developer/ceph/130-cinder.sh

#Deploy OpenvSwitch
./tools/deployment/developer/ceph/140-openvswitch.sh

#Deploy Libvirt
./tools/deployment/developer/ceph/150-libvirt.sh

#Deploy Compute Kit(Nova and Neutron)
./tools/deployment/developer/ceph/160-compute-kit.sh

#Setup the gateway to the public network
./tools/deployment/developer/ceph/170-setup-gateway.sh

echo "Successfully deployed😀"
echo "login admin as username and password for password"
