# The droplet predates this configuration: deploy/digitalocean/deploy.sh
# created it (image ubuntu-24-04-x64, cloud-init user_data installing
# docker + swap + ufw) and still owns everything ON the box. OpenTofu
# owns the box itself: that it exists, its size, its region, and the
# cloud firewall in front of it. Verified live 2026-08-14:
# id=585464063, name=onym-infra, ams3, s-1vcpu-2gb, 159.223.218.40.

resource "digitalocean_droplet" "onym_infra" {
  name   = var.droplet_name
  region = var.droplet_region
  size   = var.droplet_size
  image  = var.droplet_image

  lifecycle {
    # This box holds the strfry DB, blossom blobs, and both moderation
    # SQLite stores (docker volumes, no external backup by default).
    # Nothing in a plan is allowed to delete it.
    prevent_destroy = true

    # All three predate IaC and would force replacement or churn if
    # managed: the image slug reported by the API drifts from the
    # creation slug over time, user_data was cloud-init at creation and
    # is not faithfully round-tripped, and ssh_keys are not returned on
    # import. deploy.sh remains the owner of on-box state.
    ignore_changes = [
      image,
      user_data,
      ssh_keys,
    ]
  }
}

# Cloud firewall. Verified live 2026-08-14: NO DigitalOcean firewall is
# currently attached to this droplet — today only on-box ufw (from
# cloud-init: 22/80/443) filters traffic. This resource is therefore a
# genuine CREATE on first apply, and it is belt-and-braces on top of
# ufw, not a replacement for it.
#
# Port inventory from docker-compose.yml: only caddy publishes ports —
# 80/tcp, 443/tcp, 443/udp (HTTP/3 QUIC). strfry's 7777 and every
# service :8080 stay on the private compose network behind Caddy, so
# they are deliberately NOT opened here.
resource "digitalocean_firewall" "onym_infra" {
  name        = "onym-infra-fw"
  droplet_ids = [digitalocean_droplet.onym_infra.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTP/3 — compose publishes 443/udp for QUIC.
  inbound_rule {
    protocol         = "udp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  # ICMP so path-MTU discovery and ping keep working.
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# Reserved IP: verified live 2026-08-14 that NO reserved IP is assigned
# to this droplet (the only reserved IP on the account, 165.227.247.235,
# belongs to onym-web). DNS points at the droplet's ephemeral public
# IPv4. If one is ever assigned, manage it like this and import it by
# its IP:
#
# resource "digitalocean_reserved_ip" "onym_infra" {
#   region     = var.droplet_region
#   droplet_id = digitalocean_droplet.onym_infra.id
# }
# # import: tofu import digitalocean_reserved_ip.onym_infra <the-ip>
# # ...and point the records in dns.tf at it instead of ipv4_address.

# Project membership: the droplet sits in the account's default project
# ("first-project", 8d369a2c-dbaa-4ce4-b268-64d98d58abe3) by default —
# no dedicated project is used, so none is managed here.
