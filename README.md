
# Automatically Recover ONLYOFFICE After Nextcloud AIO Nightly Backups
*A complete workaround using systemd timers, bash scripting, logrotate,  
and the removal of a problematic ONLYOFFICE background job.*  

After days of searching for a reliable way to automate the OnlyOffice availability in Nextcloud-AIO, i've decided to write my own guide.
Feel free to propose edits and to use this guide however and wherever you'd like.

---

### TL;DR
ONLYOFFICE fails its first availability check after the AIO nightly backup (04:00 UTC).  
This marks the integration as "broken" until clicking “Save” or running  
`occ onlyoffice:documentserver --check`.  
Here is a systemd-based automatic recovery workaround that fully fixes the issue.  
This does not patch AIO or ONLYOFFICE, it's fully external and safe.


---

## Overview

When running **Nextcloud AIO** together with the **ONLYOFFICE** integration, nightly backups can cause ONLYOFFICE to be marked as *broken* in the Nextcloud admin UI.

Symptoms:
- ONLYOFFICE healthcheck works fine:
  ```
  curl https://<your-domain>/onlyoffice/healthcheck
  # → true
  ```
- But after the nightly backup, the ONLYOFFICE admin panel reports:
  **“Document Server not available”** or **404 Error**
- Editing documents is disabled until you manually click **“Save”** in the ONLYOFFICE admin settings.
- Alternatively, running:
  ```
  php occ onlyoffice:documentserver --check
  ```
  instantly fixes the issue.

This happens because:
- the AIO backup stops and restarts containers at **04:00 UTC**,
- Nextcloud performs an availability check **too early**,  
- ONLYOFFICE is not yet ready,
- the failure is written into the configuration,
- and remains until manually cleared.

This document proposes a complete, reliable, automated workaround.

---

## Summary of the Solution

### 0. (Optional) Set “Availability check interval” to **0 minutes**
In the ONLYOFFICE admin panel:

**Settings → ONLYOFFICE → Availability check interval → set to `0`**

This reduces periodic background checks,  
**BUT on its own it does *not* fix the nightly-backup issue.**

It must be combined with the rest of this workaround.

---

### 1. Disable ONLYOFFICE background cron job that incorrectly marks configuration as failed.  
You will comment the `EditorsCheck` job from `info.xml`.

### 2. Create an automatic **systemd timer** on the Docker host  
that runs:
```
occ onlyoffice:documentserver --check
```
- every 5 minutes between **04:10–04:40 UTC** (right after backups)
- once per hour thereafter (safety)

### 3. Add log rotation with logrotate.

### 4. No modification of ONLYOFFICE PHP code required.

---

# 1. Disable ONLYOFFICE EditorsCheck Job

Inside the `nextcloud-aio-nextcloud` container:

```bash
docker exec -it nextcloud-aio-nextcloud bash
cd /var/www/html/custom_apps/onlyoffice/appinfo
cp info.xml info.xml.bak.$(date +%s)
nano info.xml
```

Comment this block:

```xml
<!--
<background-jobs>
    <job>OCA\Onlyoffice\Cron\EditorsCheck</job>
</background-jobs>
-->
```

⚠ **Note:** Upgrading the ONLYOFFICE app will overwrite this file; the modification must be reapplied.

---

# 2. Auto-Fix Script (host system)

Create the script:

`/usr/local/sbin/onlyoffice-auto-fix.sh`

```bash
#!/bin/bash

LOCK="/tmp/onlyoffice-check.lock"
LOG="/var/log/onlyoffice-auto-fix.log"

if [ -f "$LOCK" ]; then
    echo "$(date '+%F %T') : lock present, skipping" >> "$LOG"
    exit 0
fi

touch "$LOCK"

{
    echo " "
    echo "===== $(date '+%F %T') : Running OnlyOffice check ====="

    docker exec nextcloud-aio-nextcloud \
        sudo -E -u www-data php occ onlyoffice:documentserver --check

    STATUS=$?

    if [ $STATUS -eq 0 ]; then
        echo "$(date '+%F %T') : OK ✓"
    else
        echo "$(date '+%F %T') : ERROR – DocumentServer not ready ❌"
    fi

} >> "$LOG" 2>&1

rm -f "$LOCK"
```

Permissions:

```bash
sudo chmod +x /usr/local/sbin/onlyoffice-auto-fix.sh
sudo touch /var/log/onlyoffice-auto-fix.log
sudo chmod 644 /var/log/onlyoffice-auto-fix.log
```

---

# 3. Systemd Service

`/etc/systemd/system/onlyoffice-fix.service`

```ini
[Unit]
Description=Auto-fix OnlyOffice for Nextcloud AIO
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/onlyoffice-auto-fix.sh
```

---

# 4. Systemd Timer (UTC-based)

Backups run at **04:00 UTC**.  
We trigger checks 10–40 minutes after backup, then every hour.

`/etc/systemd/system/onlyoffice-fix.timer`

```ini
[Unit]
Description=Run OnlyOffice auto-fix after Nextcloud AIO backup

[Timer]
# Primary window: every 5 minutes between 04:10–04:40 UTC
OnCalendar=*-*-* 04:10:00..04:40:00/5 UTC

# Safety run: once per hour at minute 10 (UTC)
OnCalendar=*-*-* *:10:00 UTC

Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now onlyoffice-fix.timer
systemctl list-timers | grep onlyoffice
```

---

# 5. Log Rotation

Create:

`/etc/logrotate.d/onlyoffice-auto-fix`

```conf
/var/log/onlyoffice-auto-fix.log {
    daily
    rotate 90
    size 5M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
```

This keeps ~3 months of compressed logs.

---

# Final Result

- ONLYOFFICE no longer breaks after nightly backups  
- The system auto-recovers as soon as DocumentServer becomes available  
- Absolutely no need to manually click “Save” in the admin UI  
- No patching of ONLYOFFICE PHP code  
- Log size stays under control  
- Timer works even if execution was missed (`Persistent=true`)  

---

# Disclaimer

 - This documentation was generated with the help of an AI assistant and validated through practical testing on a real Nextcloud AIO + ONLYOFFICE deployment.

 - Docker host is a Debian 13 VPS.
 
 - I use **Zoraxy** as reverse-proxy:
 `aio.cloud.domain.tld` ==> `nextcloud-aio-mastercontainer:8080` (endpoint requires https/SSL + ignore cert validity)
 `cloud.domain.tld` ==> `nextcloud-aio-apache:11000` (endpoint is plain http/no-SSL)
<img width="1116" height="252" alt="Capture d&#39;écran 2025-11-23 115811" src="https://github.com/user-attachments/assets/0377e737-3759-45be-a8c4-231557c12e0f" />




 - I use **Portainer** to deploy my Nextcloud-AIO (see bellow for the docker-compose/stack yaml).

```YAML
services:
  nextcloud-aio-mastercontainer:
    image: nextcloud/all-in-one:latest
    init: true
    restart: always
    container_name: nextcloud-aio-mastercontainer # This line is not allowed to be changed as otherwise AIO will not work correctly
    volumes:
      - nextcloud_aio_mastercontainer:/mnt/docker-aio-config # This line is not allowed to be changed as otherwise the built-in backup solution will not work
      - /var/run/docker.sock:/var/run/docker.sock:ro # May be changed on macOS, Windows or docker rootless. See the applicable documentation. If adjusting, don't forget to also set 'WATCHTOWER_DOCKER_SOCKET_PATH'!
#    network_mode: bridge # add to the same network as docker run would do
    networks:
      - proxy
#    ports:
#      - 80:80 # Can be removed when running behind a web server or reverse proxy (like Apache, Nginx, Caddy, Cloudflare Tunnel and else). See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
#      - 8081:8080
#      - 8443:8443 # Can be removed when running behind a web server or reverse proxy (like Apache, Nginx, Caddy, Cloudflare Tunnel and else). See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
    environment: # Is needed when using any of the options below
      # AIO_DISABLE_BACKUP_SECTION: false # Setting this to true allows to hide the backup section in the AIO interface. See https://github.com/nextcloud/all-in-one#how-to-disable-the-backup-section
      # AIO_COMMUNITY_CONTAINERS: facerecognition # With this variable, you can add community containers very easily. See https://github.com/nextcloud/all-in-one/tree/main/community-containers#community-containers
      APACHE_PORT: 11000 # Is needed when running behind a web server or reverse proxy (like Apache, Nginx, Caddy, Cloudflare Tunnel and else). See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
      APACHE_IP_BINDING: 0.0.0.0 # Should be set when running behind a web server or reverse proxy (like Apache, Nginx, Caddy, Cloudflare Tunnel and else) that is running on the same host. See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
      APACHE_ADDITIONAL_NETWORK: proxy # (Optional) Connect the apache container to an additional docker network. Needed when behind a web server or reverse proxy (like Apache, Nginx, Caddy, Cloudflare Tunnel and else) running in a different docker network on same server. See https://github.com/nextcloud/all-in-one/blob/main/reverse-proxy.md
      # BORG_RETENTION_POLICY: --keep-within=7d --keep-weekly=4 --keep-monthly=6 # Allows to adjust borgs retention policy. See https://github.com/nextcloud/all-in-one#how-to-adjust-borgs-retention-policy
      # COLLABORA_SECCOMP_DISABLED: false # Setting this to true allows to disable Collabora's Seccomp feature. See https://github.com/nextcloud/all-in-one#how-to-disable-collaboras-seccomp-feature
      # FULLTEXTSEARCH_JAVA_OPTIONS: "-Xms1024M -Xmx1024M" # Allows to adjust the fulltextsearch java options. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-fulltextsearch-java-options
      NEXTCLOUD_DATADIR: /mnt/ncdata # Allows to set the host directory for Nextcloud's datadir. ⚠️⚠️⚠️ Warning: do not set or adjust this value after the initial Nextcloud installation is done! See https://github.com/nextcloud/all-in-one#how-to-change-the-default-location-of-nextclouds-datadir
      NEXTCLOUD_MOUNT: /mnt/ # Allows the Nextcloud container to access the chosen directory on the host. See https://github.com/nextcloud/all-in-one#how-to-allow-the-nextcloud-container-to-access-directories-on-the-host
      NEXTCLOUD_UPLOAD_LIMIT: 16G # Can be adjusted if you need more. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-upload-limit-for-nextcloud
      NEXTCLOUD_MAX_TIME: 3600 # Can be adjusted if you need more. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-max-execution-time-for-nextcloud
      NEXTCLOUD_MEMORY_LIMIT: 2048M # Can be adjusted if you need more. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-php-memory-limit-for-nextcloud
      # NEXTCLOUD_TRUSTED_CACERTS_DIR: /path/to/my/cacerts # CA certificates in this directory will be trusted by the OS of the nextcloud container (Useful e.g. for LDAPS) See https://github.com/nextcloud/all-in-one#how-to-trust-user-defined-certification-authorities-ca
      # NEXTCLOUD_STARTUP_APPS: deck twofactor_totp tasks calendar contacts notes # Allows to modify the Nextcloud apps that are installed on starting AIO the first time. See https://github.com/nextcloud/all-in-one#how-to-change-the-nextcloud-apps-that-are-installed-on-the-first-startup
      NEXTCLOUD_ADDITIONAL_APKS: imagemagick openjdk21-jre-headless openssl # This allows to add additional packages to the Nextcloud container permanently. Default is imagemagick but can be overwritten by modifying this value. See https://github.com/nextcloud/all-in-one#how-to-add-os-packages-permanently-to-the-nextcloud-container
      NEXTCLOUD_ADDITIONAL_PHP_EXTENSIONS: tidy uuid xxtea gnupg gmagick imagick openssl # This allows to add additional php extensions to the Nextcloud container permanently. Default is imagick but can be overwritten by modifying this value. See https://github.com/nextcloud/all-in-one#how-to-add-php-extensions-permanently-to-the-nextcloud-container
      # NEXTCLOUD_ENABLE_DRI_DEVICE: true # This allows to enable the /dev/dri device for containers that profit from it. ⚠️⚠️⚠️ Warning: this only works if the '/dev/dri' device is present on the host! If it should not exist on your host, don't set this to true as otherwise the Nextcloud container will fail to start! See https://github.com/nextcloud/all-in-one#how-to-enable-hardware-acceleration-for-nextcloud
      # NEXTCLOUD_ENABLE_NVIDIA_GPU: true # This allows to enable the NVIDIA runtime and GPU access for containers that profit from it. ⚠️⚠️⚠️ Warning: this only works if an NVIDIA gpu is installed on the server. See https://github.com/nextcloud/all-in-one#how-to-enable-hardware-acceleration-for-nextcloud.
      # NEXTCLOUD_KEEP_DISABLED_APPS: false # Setting this to true will keep Nextcloud apps that are disabled in the AIO interface and not uninstall them if they should be installed. See https://github.com/nextcloud/all-in-one#how-to-keep-disabled-apps
      # SKIP_DOMAIN_VALIDATION: false # This should only be set to true if things are correctly configured. See https://github.com/nextcloud/all-in-one?tab=readme-ov-file#how-to-skip-the-domain-validation
      TALK_PORT: 3478 # This allows to adjust the port that the talk container is using which is exposed on the host. See https://github.com/nextcloud/all-in-one#how-to-adjust-the-talk-port
      # WATCHTOWER_DOCKER_SOCKET_PATH: /var/run/docker.sock # Needs to be specified if the docker socket on the host is not located in the default '/var/run/docker.sock'. Otherwise mastercontainer updates will fail. For macos it needs to be '/var/run/docker.sock'
    # security_opt: ["label:disable"] # Is needed when using SELinux

#   # Optional: Caddy reverse proxy. See https://github.com/nextcloud/all-in-one/discussions/575
#   # Alternatively, use Tailscale if you don't have a domain yet. See https://github.com/nextcloud/all-in-one/discussions/5439
#   # Hint: You need to uncomment APACHE_PORT: 11000 above, adjust cloud.example.com to your domain and uncomment the necessary docker volumes at the bottom of this file in order to make it work
#   # You can find further examples here: https://github.com/nextcloud/all-in-one/discussions/588
#   caddy:
#     image: caddy:alpine
#     restart: always
#     container_name: caddy
#     volumes:
#       - caddy_certs:/certs
#       - caddy_config:/config
#       - caddy_data:/data
#       - caddy_sites:/srv
#     network_mode: "host"
#     configs:
#       - source: Caddyfile
#         target: /etc/caddy/Caddyfile
# configs:
#   Caddyfile:
#     content: |
#       # Adjust cloud.example.com to your domain below
#       https://cloud.example.com:443 {
#         reverse_proxy localhost:11000
#       }

volumes: # If you want to store the data on a different drive, see https://github.com/nextcloud/all-in-one#how-to-store-the-filesinstallation-on-a-separate-drive
  nextcloud_aio_mastercontainer:
    name: nextcloud_aio_mastercontainer # This line is not allowed to be changed as otherwise the built-in backup solution will not work
  # caddy_certs:
  # caddy_config:
  # caddy_data:
  # caddy_sites:

networks:
  proxy:
    external: true
```
---
