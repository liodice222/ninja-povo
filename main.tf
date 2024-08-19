resource "oci_core_instance" "this_instance" {
    for_each = { for i, name in local.input : name.name => name }
    display_name = each.value.name
    compartment_id = local.compartment_ids[each.value.compartment]
    #hostname_label = Deprecated. Use hostname_label in create_vnic_details
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    shape = each.value.shape
    is_pv_encryption_in_transit_enabled = try(lower(each.value.shielded),null) == "true" ? true : null
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    create_vnic_details {
        subnet_id = join("",local.all_subnet_ids[each.value.subnet])
        assign_public_ip = try(lower(each.value.public),false)
        private_ip = try(each.value.ip,null)
        hostname_label = try(each.value.dns, "") != "" ? each.value.dns : substr(lower(replace(each.value.name,"/\\W|_|\\s/","")),0,64)
        nsg_ids = compact(concat(try(local.all_nsg_ids[each.value.nsg1],[""]),try(local.all_nsg_ids[each.value.nsg2],[""]),try(local.all_nsg_ids[each.value.nsg3],[""]),try(local.all_nsg_ids[each.value.nsg4],[""]),try(local.all_nsg_ids[each.value.nsg5],[""])))
    }
    # Assign Fault Domain
    fault_domain = try(each.value.fault_domain,"") == "" ? "" : join("-",["FAULT-DOMAIN",each.value.fault_domain])
    shape_config {
        ocpus = each.value.ocpus
        memory_in_gbs = each.value.memory
    }
    # Deploy base Linux Image from OCI
    dynamic "source_details" {
        for_each = try(lower(each.value.os),"") == "linux" && try(each.value.ocid, "") == "" ? [1] : []
        content {
            source_id = floor(each.value.version) == 6 ? data.oci_core_images.linux610.images.0.id : floor(each.value.version) == 8 ? data.oci_core_images.linux8.images.0.id : floor(each.value.version) == 9 ? data.oci_core_images.linux9.images.0.id : data.oci_core_images.linux79.images.0.id
            source_type = try(lower(each.value.type),"") == "bootvolume" ? "bootVolume" : "image"
            boot_volume_size_in_gbs = try(each.value.bootsize,"") != "" && lower(each.value.type) == "image" ? each.value.bootsize : null
            kms_key_id = try(each.value.kms_key,null)
        }
    }
    # Assign SSH key in "keys/" folder that is a sub-folder to the csv directory
    metadata = {
        ssh_authorized_keys = try(lower(each.value.os),"") == "linux" && try(each.value.ssh_key,"") != "" ? var.keys[each.value.ssh_key] : null         
    }
    # Deploy base Windows Image from OCI. VM only, does NOT support bare metal
    dynamic "source_details" {
        for_each = try(lower(each.value.os),"") == "windows" && try(each.value.ocid, "") == "" ? [1] : []
        content {
            source_id = each.value.version == "2012" ? data.oci_core_images.windows2012.images.0.id : each.value.version == "2016" ? data.oci_core_images.windows2016.images.0.id : data.oci_core_images.windows2019.images.0.id    
            source_type = try(lower(each.value.type),"") == "bootvolume" ? "bootVolume" : "image"
            boot_volume_size_in_gbs = try(each.value.bootsize,"") != "" && lower(each.value.type) == "image" ? each.value.bootsize : null
            kms_key_id = try(each.value.kms_key,null)
        }
    }
    # Deploy instance via Boot Volume OCID
    dynamic "source_details" {
        for_each = try(each.value.ocid, "") != "" ? [1] : []
        content {
            source_id = each.value.ocid
            source_type = try(lower(each.value.type),"") == "bootvolume" ? "bootVolume" : "image"
            boot_volume_size_in_gbs = try(each.value.bootsize,"") != "" && lower(each.value.type) == "image" ? each.value.bootsize : null
            kms_key_id = try(each.value.kms_key,null)
        }
    }
    dynamic "platform_config" {
        for_each = try(lower(each.value.shielded),"") == "true" ? [1] : []
        content {
            type = length(regexall("VM.Standard.E",each.value.shape)) > 0 ? "AMD_VM" : "INTEL_VM"
            is_measured_boot_enabled = true
            is_secure_boot_enabled = true
            is_trusted_platform_module_enabled = true
        }
    }
    dynamic "launch_options" {
        for_each = try(lower(each.value.shielded),"") == "true" ? [1] : []
        content {
            boot_volume_type = "PARAVIRTUALIZED"
            firmware = "UEFI_64"
            network_type = "PARAVIRTUALIZED"
            remote_data_volume_type = "PARAVIRTUALIZED"
        }
    }
    lifecycle {
        ignore_changes = [defined_tags, source_details, create_vnic_details.0.defined_tags]
    }
}

####################################################################
# Create New Block Volume and add to volume group with boot volume #
####################################################################

### New Volume 1 ###

resource "oci_core_volume" "this_volume_new_v1" {
    for_each = { for name in local.input : name.name => name if try(name.new_v1,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv1"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v1
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v1" {
    for_each = { for name in local.input : name.name => name if try(name.new_v1,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v1[each.key].id
    display_name = join("-",[each.value.name,"bv1-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 2 ###

resource "oci_core_volume" "this_volume_new_v2" {
    for_each = { for name in local.input : name.name => name if try(name.new_v2,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv2"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v2
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v2" {
    for_each = { for name in local.input : name.name => name if try(name.new_v2,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v2[each.key].id
    display_name = join("-",[each.value.name,"bv2-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 3 ###

resource "oci_core_volume" "this_volume_new_v3" {
    for_each = { for name in local.input : name.name => name if try(name.new_v3,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv3"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v3
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v3" {
    for_each = { for name in local.input : name.name => name if try(name.new_v3,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v3[each.key].id
    display_name = join("-",[each.value.name,"bv3-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 4 ###

resource "oci_core_volume" "this_volume_new_v4" {
    for_each = { for name in local.input : name.name => name if try(name.new_v4,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv4"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v4
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v4" {
    for_each = { for name in local.input : name.name => name if try(name.new_v4,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v4[each.key].id
    display_name = join("-",[each.value.name,"bv4-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 5 ###

resource "oci_core_volume" "this_volume_new_v5" {
    for_each = { for name in local.input : name.name => name if try(name.new_v5,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv5"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v5
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v5" {
    for_each = { for name in local.input : name.name => name if try(name.new_v5,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v5[each.key].id
    display_name = join("-",[each.value.name,"bv5-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 6 ###

resource "oci_core_volume" "this_volume_new_v6" {
    for_each = { for name in local.input : name.name => name if try(name.new_v6,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv6"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v6
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v6" {
    for_each = { for name in local.input : name.name => name if try(name.new_v6,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v6[each.key].id
    display_name = join("-",[each.value.name,"bv6-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 7 ###

resource "oci_core_volume" "this_volume_new_v7" {
    for_each = { for name in local.input : name.name => name if try(name.new_v7,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv7"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v7
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v7" {
    for_each = { for name in local.input : name.name => name if try(name.new_v7,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v7[each.key].id
    display_name = join("-",[each.value.name,"bv7-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 8 ###

resource "oci_core_volume" "this_volume_new_v8" {
    for_each = { for name in local.input : name.name => name if try(name.new_v8,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv8"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v8
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v8" {
    for_each = { for name in local.input : name.name => name if try(name.new_v8,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v8[each.key].id
    display_name = join("-",[each.value.name,"bv8-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### New Volume 9 ###

resource "oci_core_volume" "this_volume_new_v9" {
    for_each = { for name in local.input : name.name => name if try(name.new_v9,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    availability_domain = try(each.value.ad,null) == null ? element(local.ADs, 0) : element(local.ADs, each.value.ad - 1)
    display_name = join("-",[each.value.name,"bv9"])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    kms_key_id = try(each.value.kms_key,null)
    size_in_gbs = each.value.new_v9
    lifecycle {
        ignore_changes = [defined_tags,]
    }
}

resource "oci_core_volume_attachment" "this_volume_attachment_new_v9" {
    for_each = { for name in local.input : name.name => name if try(name.new_v9,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = oci_core_volume.this_volume_new_v9[each.key].id
    display_name = join("-",[each.value.name,"bv9-attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

### Create Volume Group for New Block Volumes and Boot Volume ###

resource "oci_core_volume_group" "this_volume_group_new_bv" {
    for_each = { for name in local.input : name.name => name }
    #depends_on = [oci_core_instance.this_instance]
    compartment_id = local.compartment_ids[each.value.compartment]
    display_name = join("-",[each.value.name,"volume-group"])
    availability_domain = oci_core_instance.this_instance[each.key].availability_domain
    source_details {
        type = "volumeIds"
        volume_ids = compact([
            oci_core_instance.this_instance[each.key].boot_volume_id,
            try(oci_core_volume.this_volume_new_v1[each.key].id,null),
            try(oci_core_volume.this_volume_new_v2[each.key].id,null),
            try(oci_core_volume.this_volume_new_v3[each.key].id,null),
            try(oci_core_volume.this_volume_new_v4[each.key].id,null),
            try(oci_core_volume.this_volume_new_v5[each.key].id,null),
            try(oci_core_volume.this_volume_new_v6[each.key].id,null),
            try(oci_core_volume.this_volume_new_v7[each.key].id,null),
            try(oci_core_volume.this_volume_new_v8[each.key].id,null),
            try(oci_core_volume.this_volume_new_v9[each.key].id,null)
        ])
    }
    #backup_policy_id = try(each.value.backup-policy,"") == "" ? null : join("",local.backup_policy_ids[each.value.backup-policy])
    # Backup policy cannot be changed in Volume Group resource as it will force replacement. Use oci_core_volume_backup_policy_assignment for volume group backup policy
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    lifecycle {
        ignore_changes = [defined_tags,source_details,]
    }
}

# Assign backup policy to volume group. Currently volume_group resource does not accept updating backup policy without forcing a replacement of the resource
resource "oci_core_volume_backup_policy_assignment" "this_volume_group_new_bv_backup_policy_assignment" {
    for_each = { for name in local.input : name.name => name if try(name.backup-policy,"") != "" }
    #depends_on = [oci_core_volume_group.this_volume_group_new_bv]
    asset_id = oci_core_volume_group.this_volume_group_new_bv[each.key].id
    policy_id = try(each.value.backup-policy,"") == "" ? null : join("",local.backup_policy_ids[each.value.backup-policy])
}



#########################################################################
# Attach Existing Block Volume and add to volume group with boot volume #
#########################################################################

resource "oci_core_volume_attachment" "this_volume_attachment_v1" {
    for_each = { for name in local.input : name.name => name if try(name.v1,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v1])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v1,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v2" {
    for_each = { for name in local.input : name.name => name if try(name.v2,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v2])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v2,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v3" {
    for_each = { for name in local.input : name.name => name if try(name.v3,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v3])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v3,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v4" {
    for_each = { for name in local.input : name.name => name if try(name.v4,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v4])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v4,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v5" {
    for_each = { for name in local.input : name.name => name if try(name.v5,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v5])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v5,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v6" {
    for_each = { for name in local.input : name.name => name if try(name.v6,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v6])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v6,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v7" {
    for_each = { for name in local.input : name.name => name if try(name.v7,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v7])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v7,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v8" {
    for_each = { for name in local.input : name.name => name if try(name.v8,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v8])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v8,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_attachment" "this_volume_attachment_v9" {
    for_each = { for name in local.input : name.name => name if try(name.v9,"") != "" }
    attachment_type = "PARAVIRTUALIZED"
    instance_id = oci_core_instance.this_instance[each.key].id
    volume_id = join("",local.volume_ids[each.value.v9])
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.v9,"attachment"])
    is_pv_encryption_in_transit_enabled = try(lower(each.value.it-encrypt),"") == "true" || try(each.value.it-encrypt,"") == "1" ? true : false
}

resource "oci_core_volume_group" "this_volume_group_existing_bv" {
    for_each = { for i, name in local.input : name.name => name if try(name.v1,"") != "" }
    compartment_id = local.compartment_ids[each.value.compartment]
    display_name = join("-",[each.value.name,"volume-group"])
    availability_domain = oci_core_instance.this_instance[each.key].availability_domain
    source_details {
        type = "volumeIds"
        volume_ids = compact([
            oci_core_instance.this_instance[each.key].boot_volume_id,
            try(join("",local.volume_ids[each.value.v1]),""),
            try(join("",local.volume_ids[each.value.v2]),""),
            try(join("",local.volume_ids[each.value.v3]),""),
            try(join("",local.volume_ids[each.value.v4]),""),
            try(join("",local.volume_ids[each.value.v5]),""),
            try(join("",local.volume_ids[each.value.v6]),""),
            try(join("",local.volume_ids[each.value.v7]),""),
            try(join("",local.volume_ids[each.value.v8]),""),
            try(join("",local.volume_ids[each.value.v9]),"")
        ])
    }
    backup_policy_id = try(each.value.backup-policy,"") == "" ? null : join("",local.backup_policy_ids[each.value.backup-policy])
    defined_tags = {for tag in split(";",each.value.tags) :
        replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
        if try(each.value.tags,"") != ""
    }
    lifecycle {
        ignore_changes = [defined_tags]
    }
}

######################################
# Create and attach additional VNICs #
######################################

resource "oci_core_vnic_attachment" "this_vnic_attachment_02" {
    for_each = { for name in local.input : name.name => name if try(name.vnic_02,"") != "" }
    create_vnic_details {
        assign_private_dns_record = true
        assign_public_ip = try(lower(each.value.vnic_02_public),false)
        defined_tags = {for tag in split(";",each.value.tags) :
            replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
            if try(each.value.tags,"") != ""
        }
        display_name = each.value.vnic_02
        #hostname_label = each.value.vnic_02_hostname
        nsg_ids = compact(concat(try(local.all_nsg_ids[each.value.vnic_02_nsg1],[""]),try(local.all_nsg_ids[each.value.vnic_02_nsg2],[""]),try(local.all_nsg_ids[each.value.vnic_02_nsg3],[""]),try(local.all_nsg_ids[each.value.vnic_02_nsg4],[""]),try(local.all_nsg_ids[each.value.vnic_02_nsg5],[""])))
        private_ip = try(each.value.vnic_02_ip,null)
        skip_source_dest_check = try(each.value.vnic_02_thru, "false") == "true" ? true : false
        subnet_id = try(join("",local.all_subnet_ids[each.value.vnic_02_subnet]),join("",local.all_subnet_ids[each.value.subnet]))
    }
    instance_id = oci_core_instance.this_instance[each.key].id
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.vnic_02,"attachment"])
}

resource "oci_core_vnic_attachment" "this_vnic_attachment_03" {
    for_each = { for name in local.input : name.name => name if try(name.vnic_03,"") != "" }
    depends_on = [oci_core_vnic_attachment.this_vnic_attachment_02]
    create_vnic_details {
        assign_private_dns_record = true
        assign_public_ip = try(lower(each.value.vnic_03_public),false)
        defined_tags = {for tag in split(";",each.value.tags) :
            replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
            if try(each.value.tags,"") != ""
        }
        display_name = each.value.vnic_03
        #hostname_label = each.value.vnic_03_hostname
        nsg_ids = compact(concat(try(local.all_nsg_ids[each.value.vnic_03_nsg1],[""]),try(local.all_nsg_ids[each.value.vnic_03_nsg2],[""]),try(local.all_nsg_ids[each.value.vnic_03_nsg3],[""]),try(local.all_nsg_ids[each.value.vnic_03_nsg4],[""]),try(local.all_nsg_ids[each.value.vnic_03_nsg5],[""])))
        private_ip = try(each.value.vnic_03_ip,null)
        skip_source_dest_check = try(each.value.vnic_03_thru, "false") == "true" ? true : false
        subnet_id = try(join("",local.all_subnet_ids[each.value.vnic_03_subnet]),join("",local.all_subnet_ids[each.value.subnet]))
    }
    instance_id = oci_core_instance.this_instance[each.key].id
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.vnic_03,"attachment"])
}

resource "oci_core_vnic_attachment" "this_vnic_attachment_04" {
    for_each = { for name in local.input : name.name => name if try(name.vnic_04,"") != "" }
    depends_on = [oci_core_vnic_attachment.this_vnic_attachment_03]
    create_vnic_details {
        assign_private_dns_record = true
        assign_public_ip = try(lower(each.value.vnic_04_public),false)
        defined_tags = {for tag in split(";",each.value.tags) :
            replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
            if try(each.value.tags,"") != ""
        }
        display_name = each.value.vnic_04
        #hostname_label = each.value.vnic_04_hostname
        nsg_ids = compact(concat(try(local.all_nsg_ids[each.value.vnic_04_nsg1],[""]),try(local.all_nsg_ids[each.value.vnic_04_nsg2],[""]),try(local.all_nsg_ids[each.value.vnic_04_nsg3],[""]),try(local.all_nsg_ids[each.value.vnic_04_nsg4],[""]),try(local.all_nsg_ids[each.value.vnic_04_nsg5],[""])))
        private_ip = try(each.value.vnic_04_ip,null)
        skip_source_dest_check = try(each.value.vnic_04_thru, "false") == "true" ? true : false
        subnet_id = try(join("",local.all_subnet_ids[each.value.vnic_04_subnet]),join("",local.all_subnet_ids[each.value.subnet]))
    }
    instance_id = oci_core_instance.this_instance[each.key].id
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.vnic_04,"attachment"])
}

resource "oci_core_vnic_attachment" "this_vnic_attachment_05" {
    for_each = { for name in local.input : name.name => name if try(name.vnic_05,"") != "" }
    depends_on = [oci_core_vnic_attachment.this_vnic_attachment_04]
    create_vnic_details {
        assign_private_dns_record = true
        assign_public_ip = try(lower(each.value.vnic_05_public),false)
        defined_tags = {for tag in split(";",each.value.tags) :
            replace(regex(".+=",tag),"=","") => replace(regex("=.+",tag),"=","")
            if try(each.value.tags,"") != ""
        }
        display_name = each.value.vnic_05
        #hostname_label = each.value.vnic_05_hostname
        nsg_ids = compact(concat(try(local.all_nsg_ids[each.value.vnic_05_nsg1],[""]),try(local.all_nsg_ids[each.value.vnic_05_nsg2],[""]),try(local.all_nsg_ids[each.value.vnic_05_nsg3],[""]),try(local.all_nsg_ids[each.value.vnic_05_nsg4],[""]),try(local.all_nsg_ids[each.value.vnic_05_nsg5],[""])))
        private_ip = try(each.value.vnic_05_ip,null)
        skip_source_dest_check = try(each.value.vnic_05_thru, "false") == "true" ? true : false
        subnet_id = try(join("",local.all_subnet_ids[each.value.vnic_05_subnet]),join("",local.all_subnet_ids[each.value.subnet]))
    }
    instance_id = oci_core_instance.this_instance[each.key].id
    display_name = join("-",[oci_core_instance.this_instance[each.key].display_name,each.value.vnic_05,"attachment"])
}