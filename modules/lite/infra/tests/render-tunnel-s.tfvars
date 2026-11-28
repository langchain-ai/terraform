# scripts/render.sh: box s behind a Cloudflare Tunnel, with a measured override.
cloud                 = "baremetal"
ssh_host              = "box.example.com"
box                   = "s"
access                = "tunnel"
domain                = "langsmith.example.com"
tunnel_token          = "render-only"
langsmith_license_key = "render-only"
resources = {
  queue = { cpu_m = 150, mem_mi = 1200, lim_cpu_m = 1000, lim_mem_mi = 2400 }
}
