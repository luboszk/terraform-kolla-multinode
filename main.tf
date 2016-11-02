provider "openstack" { }

resource "openstack_compute_keypair_v2" "internal-key" {
    name = "${var.prefix}internal-key"
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC6e8ZTd8j7LvzRmeJCBPaHCdd6pXKo2PeDoqAG9QoUY+ABuU7jOK4WoRn1EsMr1k5tr32ePmZ+6AKmPVFQM2QlJE3fqFxIr6WJH4XI2rqDcq61bFs51ngJS6/vsh63ksqUn7nnoycHJx4kgeIhr6T2LEHIc2rDMewoGd8o0+9MRKZz8n/RgUVpnmpLu0dbwNnSv1H7QhE1GiqDXozTWjLHQiJdAudDhoSqFxsdIdwChzYyKZZ/uJ4zAmYCWl8X1cF+TxT39yJI+OCjDSGPDE6597iCm20ctFvdGn7kZSQnSscjK0T3M1MBOrv6xiAKG9nw3YbmF+ZuX0bfZX4SnP5B"
}

resource "openstack_networking_network_v2" "mgmt_network" {
    name = "${var.prefix}mgmt-net"
}

resource "openstack_networking_subnet_v2" "mgmt_subnet_network" {
    name = "${var.prefix}mgmt-subnet"
    network_id = "${openstack_networking_network_v2.mgmt_network.id}"
    cidr = "192.168.50.0/24"
    ip_version = 4
    dns_nameservers = ["8.8.8.8","8.8.4.4"]
}

resource "openstack_networking_network_v2" "second_network" {
    name = "${var.prefix}mgmt-net"
}

resource "openstack_networking_subnet_v2" "second_subnet_network" {
    name = "${var.prefix}second-subnet"
    network_id = "${openstack_networking_network_v2.second_network.id}"
    cidr = "192.168.60.0/24"
    ip_version = 4
}

resource "openstack_networking_router_interface_v2" "router_interface" {
    router_id = "88575ebe-a83f-4a20-9fc5-6a2f5ca812b0"
    subnet_id = "${openstack_networking_subnet_v2.mgmt_subnet_network.id}"
}

resource "openstack_networking_floatingip_v2" "floating_ip" {
    pool = "GATEWAY_NET"
}

resource "openstack_compute_instance_v2" "controller" {
    count = "${var.controller_count}"
    name = "${var.prefix}controller-node${count.index + 1}"
    image_name = "ubuntu-16.04-cloud"
    flavor_name = "m2.medium"
    key_pair = "${var.prefix}internal-key"

    network {
        uuid = "${openstack_networking_network_v2.mgmt_network.id}"
        fixed_ip_v4 = "192.168.50.${count.index + 5}"
    }

    network {
        uuid = "${openstack_networking_network_v2.second_network.id}"
        fixed_ip_v4 = "192.168.60.${count.index + 5}"
    }
}

resource "openstack_compute_instance_v2" "compute" {
    count = "${var.compute_count}"
    name = "${var.prefix}compute-node${count.index + 1}"
    image_name = "ubuntu-16.04-cloud"
    flavor_name = "m2.medium"
    key_pair = "${var.prefix}internal-key"

    network {
        uuid = "${openstack_networking_network_v2.mgmt_network.id}"
        fixed_ip_v4 = "192.168.50.${count.index + 10}"
        access_network = true
    }

    network {
        uuid = "${openstack_networking_network_v2.second_network.id}"
        fixed_ip_v4 = "192.168.60.${count.index + 10}"
    }

    block_device {
        uuid = "59d44110-f1cd-4532-8bd4-18d48420366e"
        boot_index = 0
        delete_on_termination = true
        destination_type = "local"
        source_type = "image"
        volume_size = 50
    }

    block_device {
        boot_index = -1
        delete_on_termination = true
        destination_type = "volume"
        source_type = "blank"
        volume_size = 100
    }
}

resource "openstack_compute_instance_v2" "deployer" {
    name = "${var.prefix}deployer"
    image_name = "ubuntu-16.04-cloud"
    flavor_name = "m2.medium"
    key_pair = "${var.key_pair}"
    security_groups = ["default"]

    network {
        uuid = "${openstack_networking_network_v2.mgmt_network.id}"
        floating_ip = "${openstack_networking_floatingip_v2.floating_ip.address}"
        access_network = true
    }

    connection {
        user = "ubuntu"
        private_key = "${file("~/.ssh/id_rsa")}"
    }

    provisioner "file" {
        source = "internal_key"
        destination = "/home/ubuntu/.ssh/id_rsa"
    }

    provisioner "file" {
        content = "export CONTROLLER_COUNT=${var.controller_count}\nexport COMPUTE_COUNT=${var.compute_count}"
        destination = "~ubuntu/counts.sh"
    }
    
    provisioner "remote-exec" {
        script = "multinode.sh"
    }
}
