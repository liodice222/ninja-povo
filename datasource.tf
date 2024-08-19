### Lookup all compartments in tenancy ###
data "oci_identity_compartments" "compartment_tree" {
  compartment_id            = var.tenancy_ocid
  compartment_id_in_subtree = true
  access_level = "ACCESSIBLE"
  state = "ACTIVE"
}

locals {
  # Create compartment dictionary matching up names to ocids
  pre_compartment_ids = {for compartment in data.oci_identity_compartments.compartment_tree.compartments : compartment.name => compartment.id ...}

  compartment_ids = {for key, compartment in local.pre_compartment_ids : key => compartment[0]}

  # parse and convert 'csv' file to object
  input = csvdecode(var.csv)

  # Lookup ADs in region
  ADs = [for i in data.oci_identity_availability_domains.ad.availability_domains : i.name]
  
  all_subnet_ids = merge(flatten([
      for compartment in data.oci_core_subnets.all_subnet_tree : {
        for subnet in coalesce(compartment.subnets, []) : 
          subnet.display_name => subnet.id
      ...}
  ])...)

  all_nsg_ids = merge(flatten([
      for compartment in data.oci_core_network_security_groups.all_nsg_tree : {
        for nsg in coalesce(compartment.network_security_groups, []) : 
          nsg.display_name => nsg.id
      ...}
  ])...)

  volume_ids = merge(flatten([
    for compartment in data.oci_core_volumes.volumes_tree : {
      for bv in coalesce(compartment.volumes, []) :
        bv.display_name => bv.id
      ...}
  ])...)

  backup_policy_ids = merge(flatten([
    for compartment in data.oci_core_volume_backup_policies.backup_policies_tree : {
      for policy in coalesce(compartment.volume_backup_policies, []) : 
        policy.display_name => policy.id
      ...}
  ])...)
}

### Pull all Availability Domains in region ###

data "oci_identity_availability_domains" "ad" {
  compartment_id = var.tenancy_ocid
}

### Pull all Subnets in tenancy where accessible ###

data "oci_core_subnets" "all_subnet_tree" {
    for_each = local.compartment_ids
      compartment_id = each.value
      state = "AVAILABLE"
}

### Pull all NSGs in tenancy where accessible ###

data "oci_core_network_security_groups" "all_nsg_tree" {
    for_each = local.compartment_ids
      compartment_id = each.value
      state = "AVAILABLE"
}

### Pull all Volumes in tenancy where accessible ###

data "oci_core_volumes" "volumes_tree" {
  for_each = local.compartment_ids
    compartment_id = each.value
}

### Pull all Backup Policies in tenancy where accessible ###

data "oci_core_volume_backup_policies" "backup_policies_tree" {
  for_each = local.compartment_ids
    compartment_id = each.value
}

### Image OCID Lookup by OS ###

data "oci_core_images" "linux610" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Oracle Linux"
    operating_system_version = "6.10"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^([a-zA-z]+)-([a-zA-z]+)-([\\.0-9]+)-([\\.0-9-]+)$"]
      regex = true
    }
}

data "oci_core_images" "linux79" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Oracle Linux"
    operating_system_version = "7.9"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^([a-zA-z]+)-([a-zA-z]+)-([\\.0-9]+)-([\\.0-9-]+)$"]
      regex = true
    }
}
data "oci_core_images" "linux8" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Oracle Linux"
    operating_system_version = "8"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^([a-zA-z]+)-([a-zA-z]+)-([\\.0-9]+)-([\\.0-9-]+)$"]
      regex = true
    }
}
data "oci_core_images" "linux9" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Oracle Linux"
    operating_system_version = "9"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^([a-zA-z]+)-([a-zA-z]+)-([\\.0-9]+)-([\\.0-9-]+)$"]
      regex = true
    }
}
data "oci_core_images" "windows2012" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Windows"
    operating_system_version = "Server 2012 R2 Standard"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^Windows-Server-2012-R2-Standard-Edition-VM-([\\.0-9-]+)$"]
      regex = true
    }
}
data "oci_core_images" "windows2016" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Windows"
    operating_system_version = "Server 2016 Standard"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^Windows-Server-2016-Standard-Edition-VM-([\\.0-9-]+)$"]
      regex = true
    }
}
data "oci_core_images" "windows2019" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Windows"
    operating_system_version = "Server 2019 Standard"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^Windows-Server-2019-Standard-Edition-VM-([\\.0-9-]+)$"]
      regex = true
    }
}

data "oci_core_images" "windows2022" {
    compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
    operating_system = "Windows"
    operating_system_version = "Server 2022 Standard"
    state = "AVAILABLE"
    filter {
      name = "display_name"
      values = ["^Windows-Server-2022-Standard-Edition-VM-([\\.0-9-]+)$"]
      regex = true
    }
}