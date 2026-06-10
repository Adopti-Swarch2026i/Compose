datacenter = "adopti-dc"
data_dir   = "/consul/data"
log_level  = "INFO"

server           = true
bootstrap_expect = 1

ui_config {
  enabled = true
}

client_addr = "0.0.0.0"
bind_addr   = "0.0.0.0"

ports {
  http = 8500
  dns  = 8600
}
