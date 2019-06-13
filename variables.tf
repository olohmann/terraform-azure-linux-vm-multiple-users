variable "resource_group_name" {
  default = "jumphost_rg"
  type = "string"
}

variable "location" {
  default = "West Europe"
  type = "string"
}

variable "vm_name" {
  default = "jumphost"
  type = "string"
}

variable "admin_username" {
  default = "azureuser"
  type = "string"
}

variable "public_ssh_key_admin" {
  type = "string"
}

variable "users" {
  description = "A list of users. All values have to be unique and will be zip-merged with the public_ssh_keys list."
  type = "list"
}

variable "public_ssh_keys" {
  description = "A list of OpenSSH compatible SSH public keys."
  type = "list"
}
