resource "azurerm_resource_group" "rg" {
  name     = "${var.resource_group_name}"
  location = "${var.location}"
}

locals {
  unique_suffix = "${substr(sha256(azurerm_resource_group.rg.id), 0, 6)}"
}

/* --- Custom initialization script to create multiple user accounts with SSH configs */
data "template_file" "init_script_inner" {
  count    = "${length(var.users)}"
  template = <<__SCRIPT__

  create_ssh_user "${element(var.users, count.index)}" "${element(var.public_ssh_keys, count.index)}"
__SCRIPT__
}

data "template_file" "init_script" {
  template = <<__SCRIPT__
#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Create a user with SSH login
function create_ssh_user()
{
  local USER=$1
  local SSH_PUBLIC_KEY=$2
  local PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

  # create a user with a random password
  useradd $USER -s /bin/bash -m
  echo $USER:$PASSWORD | chpasswd

  # add the user to the sudoers group so they can sudo
  usermod -aG sudo $USER
  echo "$USER     ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

  # add the ssh public key
  su - $USER -c "mkdir .ssh && echo $SSH_PUBLIC_KEY >> .ssh/authorized_keys && chmod 700 .ssh && chmod 600 .ssh/authorized_keys"
}

${join("\n", data.template_file.init_script_inner.*.rendered)}

__SCRIPT__
}

resource "local_file" "script" {
  content  = "${data.template_file.init_script.rendered}"
  filename = "${path.module}/init.sh"
}

resource "azurerm_storage_account" "storage" {
  name                      = "storage${local.unique_suffix}"
  resource_group_name       = "${azurerm_resource_group.rg.name}"
  location                  = "${azurerm_resource_group.rg.location}"
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  enable_blob_encryption    = true
  enable_file_encryption    = true
  enable_https_traffic_only = true

  account_kind = "StorageV2"
  access_tier  = "Hot"
}

resource "azurerm_storage_container" "container" {
  name                  = "scripts"
  resource_group_name   = "${azurerm_resource_group.rg.name}"
  storage_account_name  = "${azurerm_storage_account.storage.name}"
  container_access_type = "blob"
}

resource "azurerm_storage_blob" "vm_init_script_blob" {
  name                   = "init.sh"
  resource_group_name    = "${azurerm_resource_group.rg.name}"
  storage_account_name   = "${azurerm_storage_account.storage.name}"
  storage_container_name = "${azurerm_storage_container.container.name}"
  type                   = "block"
  source                 = "${local_file.script.filename}"
}

resource "azurerm_public_ip" "vm_pip" {
  name                    = "${var.vm_name}-pip"
  location                = "${azurerm_resource_group.rg.location}"
  resource_group_name     = "${azurerm_resource_group.rg.name}"
  allocation_method       = "Dynamic"
  idle_timeout_in_minutes = 30
  domain_name_label       = "${var.vm_name}-${local.unique_suffix}"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet"
  resource_group_name = "${azurerm_resource_group.rg.name}"
  location            = "${azurerm_resource_group.rg.location}"
  address_space       = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "subnet" {
  name                 = "subnet"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  virtual_network_name = "${azurerm_virtual_network.vnet.name}"
  address_prefix       = "10.0.0.0/24"
}

resource "azurerm_network_security_group" "nsg" {
  name                = "nsg"
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"

  security_rule {
    name                       = "SSH"
    priority                   = 1500
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "vm_nic" {
  name                = "${var.vm_name}-nic"
  location            = "${azurerm_resource_group.rg.location}"
  resource_group_name = "${azurerm_resource_group.rg.name}"

  ip_configuration {
    name                          = "${var.vm_name}-ipconfig"
    subnet_id                     = "${azurerm_subnet.subnet.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.vm_pip.id}"
  }
}

resource "azurerm_virtual_machine" "vm" {
  name                  = "${var.vm_name}-vm"
  location              = "${azurerm_resource_group.rg.location}"
  resource_group_name   = "${azurerm_resource_group.rg.name}"
  network_interface_ids = ["${azurerm_network_interface.vm_nic.id}"]
  vm_size               = "Standard_DS1_v2"

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true

  boot_diagnostics {
    enabled     = "true"
    storage_uri = "${azurerm_storage_account.storage.primary_blob_endpoint}"
  }

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name              = "${var.vm_name}-osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
    disk_size_gb      = "1023"
  }

  os_profile {
    computer_name  = "${var.vm_name}"
    admin_username = "${var.admin_username}"
  }

  os_profile_linux_config {
    disable_password_authentication = true

    ssh_keys {
      path     = "/home/${var.admin_username}/.ssh/authorized_keys"
      key_data = "${var.public_ssh_key_admin}"
    }
  }
}

resource "azurerm_virtual_machine_extension" "linux_vm_ext" {
  name                 = "${var.vm_name}_ext"
  location             = "${azurerm_resource_group.rg.location}"
  resource_group_name  = "${azurerm_resource_group.rg.name}"
  virtual_machine_name = "${azurerm_virtual_machine.vm.name}"
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  settings = <<SETTINGS
    {
        "fileUris": ["${azurerm_storage_account.storage.primary_blob_endpoint}${azurerm_storage_container.container.name}/${azurerm_storage_blob.vm_init_script_blob.name}"],
        "commandToExecute": "/bin/bash ./${azurerm_storage_blob.vm_init_script_blob.name}"
    }
SETTINGS
}

output "admin_ssh_connection" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.vm_pip.fqdn}"
}
