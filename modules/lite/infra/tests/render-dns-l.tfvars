# scripts/render.sh: box l, HTTPS on a name with Let's Encrypt, the retention and payload knobs moved.
cloud                 = "baremetal"
ssh_host              = "box.example.com"
box                   = "l"
access                = "dns"
domain                = "langsmith.example.com"
acme_email            = "ops@example.com"
short_ttl_days        = 7
long_ttl_days         = 90
max_payload_mb        = 50
langsmith_license_key = "render-only"
