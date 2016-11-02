#!/bin/bash

source ~ubuntu/counts.sh

GLOBALS_FILE=/etc/kolla/globals.yml
DOCKER_SERVICE=/etc/systemd/system/docker.service
INVENTORY=~ubuntu/kolla/ansible/inventory/multinode
DISK=/dev/vdc

PRIMARY_IP=$(hostname -I | awk '{ print $1 }')

# echo "${PRIMARY_IP} $(hostname)" | sudo tee -a /etc/hosts %>/dev/null

chmod 0600 ~ubuntu/.ssh/id_rsa

sudo apt-get update
# sudo apt-get install -y linux-image-generic-lts-wily
sudo apt-get install -y python-dev libffi-dev gcc libssl-dev ntp python-pip
sudo pip install -U pip

curl -sSL https://get.docker.io | bash
sudo cp /lib/systemd/system/docker.service ${DOCKER_SERVICE}
sudo sed -i 's/process$/process\nMountFlags=shared/' ${DOCKER_SERVICE}

# Prepare docker registry
sudo docker run -d -p 4000:5000 --restart=always --name registry registry:2
echo "DOCKER_OPTS=\"--insecure-registry ${PRIMARY_IP}:4000\"" | sudo tee -a /etc/default/docker %>/dev/null
sudo sed -i 's|Service\]|Service\]\nEnvironmentFile=/etc/default/docker/|' ${DOCKER_SERVICE}
sudo sed -i 's|ExecStart=.*|ExecStart=/usr/bin/dockerd -H fd:// $DOCKER_OPTS|' ${DOCKER_SERVICE}

sudo systemctl daemon-reload
sudo systemctl restart docker
sudo usermod -aG docker ubuntu

sudo pip install -U docker-py ansible

git clone https://git.openstack.org/openstack/kolla
sudo pip install -r kolla/requirements.txt -r kolla/test-requirements.txt
sudo cp -r etc/kolla /etc/
sudo pip install -U python-openstackclient python-neutronclient

sudo modprobe configfs
sudo systemctl start sys-kernel-config.mount

sudo sed -i 's/^#kolla_base_distro.*/kolla_base_distro: "ubuntu"/' $GLOBALS_FILE
sudo sed -i 's/^#kolla_install_type.*/kolla_install_type: "source"/' $GLOBALS_FILE
sudo sed -i 's/^kolla_internal_vip_address.*/kolla_internal_vip_address: "192.168.50.254"/' $GLOBALS_FILE
#sudo sed -i 's/^kolla_external_vip_address.*/kolla_external_vip_address: "172.99.106.249"/' $GLOBALS_FILE
sudo sed -i 's/^#network_interface.*/network_interface: "ens3"/g' $GLOBALS_FILE
sudo sed -i 's/^#neutron_external_interface.*/neutron_external_interface: "ens4"/g' $GLOBALS_FILE

# Enable required services
#sudo sed -i 's/#enable_barbican:.*/enable_barbican: "yes"/' $GLOBALS_FILE
sudo sed -i 's/#enable_cinder:.*/enable_cinder: "yes"/' $GLOBALS_FILE
# Cinder LVM backend
#sudo sed -i 's/#enable_cinder_backend_lvm:.*/enable_cinder_backend_lvm: "yes"/' $GLOBALS_FILE

sudo sed -i 's/#enable_heat:.*/enable_heat: "yes"/' $GLOBALS_FILE
sudo sed -i 's/#enable_horizon:.*/enable_horizon: "yes"/' $GLOBALS_FILE
#sudo sed -i 's/#enable_sahara:.*/enable_sahara: "yes"/' $GLOBALS_FILE
#sudo sed -i 's/#enable_murano:.*/enable_murano: "yes"/' $GLOBALS_FILE
#sudo sed -i 's/#enable_magnum:.*/enable_magnum: "yes"/' $GLOBALS_FILE
#sudo sed -i 's/#enable_manila:.*/enable_manila: "yes"/' $GLOBALS_FILE
#sudo sed -i 's/#enable_manila_backend_generic:.*/enable_manila_backend_generic: "yes"/' $GLOBALS_FILE
#sudo sed -i 's/#enable_neutron_lbaas:.*/enable_neutron_lbaas: "yes"/' $GLOBALS_FILE
sudo sed -i 's/#enable_ceph:.*/enable_ceph: "yes"/' $GLOBALS_FILE
sudo sed -i 's/#enable_ceph_rgw:.*/enable_ceph_rgw: "yes"/' $GLOBALS_FILE

# Ceilometer
sudo sed -i 's/#enable_aodh:.*/enable_aodh: "yes"/' $GLOBALS_FILE
sudo sed -i 's/#enable_ceilometer:.*/enable_ceilometer: "yes"/' $GLOBALS_FILE

# To use Gnocchi as DB in Ceilometer
sudo sed -i 's/#enable_gnocchi:.*/enable_gnocchi: "yes"/' $GLOBALS_FILE
sudo sed -i 's/#ceilometer_database_type:.*/ceilometer_database_type: "gnocchi"/' $GLOBALS_FILE

# To use MongDB as DB in Ceilometer
#sudo sed -i 's/#enable_mongodb:.*/enable_mongodb: "yes"/' $GLOBALS_FILE

sudo mkdir -p /etc/kolla/config

# Reconfigure Manila to use different Flavor ID
#cat <<-EOF | sudo tee /etc/kolla/config/manila-share.conf 
#[global]
#service_instance_flavor_id = 2
#EOF

# Reconfigure CEPH to use just 1 drive
#cat <<-EOF | sudo tee /etc/kolla/config/ceph.conf 
#[global]
#osd pool default size = 1
#osd pool default min size = 1
#EOF

# Configure inventory
sudo mkdir -p /etc/ansible
echo -e "[defaults]\nhost_key_checking = False" | sudo tee /etc/ansible/ansible.cfg %>/dev/null

sed -i "s|control01|192.168.50.[5:$(( 4 + CONTROLLER_COUNT ))] ansible_become=True|" $INVENTORY
sed -i "s|control0.||g" $INVENTORY
sed -i "s|network01|192.168.50.[5:$(( 4 + CONTROLLER_COUNT ))] ansible_become=True|g" $INVENTORY
sed -i "s|monitoring01|192.168.50.[5:$(( 4 + CONTROLLER_COUNT ))] ansible_become=True|g" $INVENTORY
sed -i "s|compute01|192.168.50.[10:$(( 9 + COMPUTE_COUNT ))] ansible_become=True|g" $INVENTORY
sed -i "s|storage01|192.168.50.[10:$(( 9 + COMPUTE_COUNT ))] ansible_become=True|g" $INVENTORY


# Install python2 required by ansible <2.2.0
ansible -m raw -i ~ubuntu/kolla/ansible/inventory/multinode -a "apt-get install -y python" all

# Configure disk to be used for Ceph
ansible -m shell -i ~ubuntu/kolla/ansible/inventory/multinode -a "parted $DISK -s -- mklabel gpt mkpart KOLLA_CEPH_OSD_BOOTSTRAP 1 -1" storage

# The rest of the commands execute from kolla dir
cd kolla

# Bootstrap servers
tools/kolla-ansible -i $INVENTORY bootstrap-servers

# Change user to Kolla
# sed -i "s|become=True|become=True ansible_user=kolla|g" $INVENTORY

# Build all images in registry
# tools/build.py -b ubuntu -t source

sudo tools/generate_passwords.py
tools/kolla-ansible -i $INVENTORY prechecks
tools/kolla-ansible -i $INVENTORY pull
tools/kolla-ansible -i $INVENTORY deploy
sudo tools/kolla-ansible post-deploy
