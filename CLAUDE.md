# Ubicloud - Local Development & Setup Guide

## Local Development

### First-time setup

1. Generate demo secrets:
   ```bash
   ./demo/generate_env
   ```

2. Create `demo/docker-compose.local.yml` (already exists in this repo).
   This file builds from source and mounts `../` so code changes reflect on the UI.
   Do NOT use the default `demo/docker-compose.yml` — it pulls the published image and ignores local changes.

3. Start with watch mode:
   ```bash
   docker compose -f demo/docker-compose.local.yml up --watch
   ```

4. Access the UI at http://localhost:3000

### Service startup order

| Service | Description | Port |
|---|---|---|
| postgres | PostgreSQL 15.8 | 5432 |
| assets-builder | Builds JS/CSS assets (Node 24.6) | — |
| db-migrator | Runs `bundle exec rake dev_up` | — |
| app | Ubicloud web app via foreman | 3000 |

---

## Cloudifying a Bare Metal Server (Hetzner)

### Prerequisites

You need a bare metal server from **Hetzner Robot** (`robot.hetzner.com`) — not Hetzner Cloud.

### Step 1 — Get Hetzner Robot API credentials

1. Log in at robot.hetzner.com
2. Top right → account name → **Settings** → **Webservice**
3. Create a webservice user and set a password
4. The username shown will look like `#ws+xxxxxxx` — the `#` is part of the username and must be included
5. After setting the password, **check your email** — Hetzner sends a confirmation link that must be clicked before the credentials work

### Step 2 — Generate an SSH key pair

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ubicloud_hetzner -C "ubicloud"
```

Add the public key to Hetzner Robot:
- Robot → your server → **SSH Keys** → Add SSH key → paste contents of `~/.ssh/ubicloud_hetzner.pub`

### Step 3 — Populate `demo/.env`

```
HETZNER_USER=#ws+xxxxxxx        # include the leading #
HETZNER_PASSWORD=your_webservice_password
HETZNER_SSH_PUBLIC_KEY=<contents of ~/.ssh/ubicloud_hetzner.pub>
HETZNER_SSH_PRIVATE_KEY=<contents of ~/.ssh/ubicloud_hetzner>
```

To get the values:
```bash
cat ~/.ssh/ubicloud_hetzner.pub   # HETZNER_SSH_PUBLIC_KEY
cat ~/.ssh/ubicloud_hetzner       # HETZNER_SSH_PRIVATE_KEY
```

### Step 4 — Verify credentials before cloudifying

```bash
curl -s -o /dev/null -w "%{http_code}" \
  -u "#ws+xxxxxxx:your_password" \
  https://robot-ws.your-server.de/server/<server_id>
```

Should return `200`. If `401`, the password is wrong or the confirmation email wasn't clicked.

### Step 5 — Verify your SSH key is on the server

The key installed on the server must match your local key. To verify:
```bash
ssh-keygen -l -E md5 -f ~/.ssh/ubicloud_hetzner.pub
```

Compare the fingerprint against the one shown in the Hetzner setup email or Robot → server → SSH Keys.

If they don't match, use rescue mode to fix it:
1. Robot → server → **Rescue** tab → select your SSH key → activate → reset server
2. SSH in, mount the disk, add your key to the installed OS:
   ```bash
   lsblk   # find the main partition
   mount /dev/sda1 /mnt
   echo "$(cat ~/.ssh/ubicloud_hetzner.pub)" >> /mnt/root/.ssh/authorized_keys
   chmod 600 /mnt/root/.ssh/authorized_keys
   umount /mnt && reboot
   ```

### Step 6 — Cloudify the server

Make sure containers are running, then:
```bash
docker exec -it ubicloud-app ./demo/cloudify_server
```

When prompted:
- **Host IP address:** your server's public IPv4
- **Host identifier:** the server number from Robot (shown as `#2942283` in the UI — do NOT include the `#`, enter digits only e.g. `2942283`)
- **Location:** select the Hetzner region matching your server

Wait for: `Your server is cloudified now.`

Then go to http://localhost:3000 to provision VMs.

---

## Custom Boot Images

Custom boot images can be added for use with VMs. The sandbox-platform project uses a custom `sandbox-noble` image.

### Adding a custom boot image

1. **Add to allowed list**: Edit `lib/option.rb` and add an entry to `Option::BootImages`:
   ```ruby
   ["sandbox-noble", "Sandbox Ubuntu Noble 24.04 (dev tools pre-installed)"],
   ```
   Then restart the app container: `docker restart ubicloud-app`

2. **Register for download**: The image must be hosted on an HTTP server accessible from the Hetzner host:
   ```ruby
   docker exec ubicloud-app ruby -e "
     require_relative 'loader'
     host = VmHost.first
     host.download_boot_image('sandbox-noble', version: '1.0.0',
       custom_url: 'http://<server-ip>/images/sandbox-noble-1.0.0.qcow2')
   "
   ```

3. **Wait for activation**: Ubicloud downloads, converts to `.raw`, and sets `activated_at`. Check status:
   ```ruby
   docker exec ubicloud-app ruby -e "
     require_relative 'loader'
     bi = VmHost.first.boot_images_dataset.where(name: 'sandbox-noble').first
     puts \"Activated: #{bi.activated_at}, Size: #{bi.size_gib}GB\"
   "
   ```

### Image format requirements

- Supported: `.raw`, `.qcow2`, `.img`, `.vhd` (all converted to `.raw`)
- Cloud-init must be pre-installed (Ubicloud injects SSH keys, users, networking via cloud-init)
- Images stored at `/var/storage/images/{name}-{version}.raw` on the host
- Each VM gets its own copy via `cp --reflink=auto`

### Current custom images

| Name | Version | Source | SHA256 |
|------|---------|--------|--------|
| `sandbox-noble` | `1.0.0` | `http://144.76.134.98/images/sandbox-noble-1.0.0.qcow2` | `b2269bb9...7fdd7e6e` |

---

## Common Gotchas

| Issue | Cause | Fix |
|---|---|---|
| `401 Unauthorized` on cloudify | Wrong Hetzner API credentials | Include `#` in `HETZNER_USER`; confirm webservice password via email link |
| SSH asks for password | Wrong SSH key on server | Use rescue mode to add the correct public key |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | Host key changed after rescue/reinstall | Run `ssh-keygen -R <ip>` then SSH again |
| Code changes not reflected in UI | Using wrong compose file | Always use `demo/docker-compose.local.yml`, not `demo/docker-compose.yml` |
| Env vars not picked up | `.env` updated after containers started | Run `docker compose ... down` then `up` again |
| Both disks show no partition table | No OS installed on server | Run `installimage` in rescue mode, select Ubuntu 24.04 (noble) |
| VM stuck at "waiting for capacity" (even without IPv4) | `ipv4_address` table is empty — host's own IP is skipped by `Address#populate_ipv4_addresses`, breaking the allocator's inner join | **Ideal fix:** purchase additional IPv4 addresses or a subnet (e.g. `/29`) from Hetzner Robot → your server → "IPs/Order". Hetzner will assign them to your server; re-running cloudify will pick them up via `pull_ips` and populate `ipv4_address` automatically. These extra IPs will then be assignable to VMs when IPv4 is requested. **Workaround (IPv6-only VMs):** if you only need IPv6, insert the host IP manually to unblock the allocator join — `docker exec ubicloud-app sh -c "cd /app && bundle exec ruby -e \"require_relative 'loader'; DB[:ipv4_address].insert(ip: '142.132.205.105', cidr: '142.132.205.105/32')\""` — then always create VMs with IPv4 **unchecked**. The host IP won't be assigned to any VM since `ip4_enabled = false`. |
