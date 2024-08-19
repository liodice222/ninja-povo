output instance_ids {
    value = {for instance in oci_core_instance.this_instance: instance.display_name => instance.id}
}