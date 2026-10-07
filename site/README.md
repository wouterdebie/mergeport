# mergeport.app

One static HTML page with local assets, served from Google Cloud Storage through
a dedicated global external HTTP(S) load balancer in `wouterdebie-personal`.
There is no web framework, build step, application server, or site analytics.
Download links go directly to
`https://github.com/wouterdebie/mergeport/releases/latest/download/Mergeport.dmg`.
Every release publishes that stable asset name, so downloads always select the
latest release without a site redeployment or a GitHub API request.

The architecture matches Davit's and Don't Miss's hosting. This site uses a
separate bucket, address, load balancer, managed certificate, and Cloud DNS
zone. No other site's resources are shared or modified. The app is free; GCP hosting still incurs
load-balancer, IP, DNS, storage, and network charges.

## Deploy content

From the repository root, select an already authenticated account explicitly:

```sh
GCLOUD_ACCOUNT="your-personal-google-account" bash site/deploy.sh
```

The command always targets `wouterdebie-personal` without changing the active
gcloud configuration. It uploads only `site/assets/` and `site/index.html`, not
scripts, infrastructure, or any app/user data. Assets are uploaded first; images
are cached for one day, while HTML and CSS revalidate on every visit. Old objects are deliberately
not deleted, protecting cached pages and anything managed independently.

Local preview: open `site/index.html` in a browser. The page works without
JavaScript or a development server.

## Infrastructure

| Resource | Name |
| --- | --- |
| Project | `wouterdebie-personal` |
| Public GCS bucket | `mergeport-app-site` (US multi-region, uniform bucket-level access) |
| Backend bucket | `mergeport-app-bucket-backend` (CDN disabled, matching Davit) |
| Reserved global IPv4 | `mergeport-app-ip`: `136.81.128.105` |
| HTTPS URL map | `mergeport-app-lb` |
| HTTP redirect URL map | `mergeport-app-lb-redirect` |
| HTTPS target proxy | `mergeport-app-lb-target-proxy` |
| HTTP target proxy | `mergeport-app-lb-http-proxy` |
| Forwarding rules | `mergeport-app-lb-https-forwarding-rule` (443), `mergeport-app-lb-http-forwarding-rule` (80) |
| Google-managed certificate | `mergeport-app-cert` (apex and `www`) |
| Cloud DNS zone | `mergeport-app` |

The bucket grants `allUsers` only `roles/storage.objectViewer`. Treat every
uploaded object as public. The direct GCS origin is also public, as with Davit.
There are no uploaded private credentials and no service-account key files.

[provision.sh](infra/provision.sh) creates missing named resources, applies the
two checked-in URL maps and bucket website/access settings, and exports the DNS
zone. It retains existing compute resources rather than silently replacing them,
and refuses to overwrite an A record pointing to a different IP. It is a
provisioning script, not a drift-reconciling infrastructure manager; inspect
existing resources before changing their settings. Run from the repository root:

```sh
GCLOUD_ACCOUNT="your-personal-google-account" bash site/infra/provision.sh
```

The project must have the Compute Engine, Cloud DNS, and Cloud Storage APIs
enabled. A fresh project also needs billing and the appropriate IAM permissions.
The script does not alter project-wide IAM, billing, or unrelated resources.

HTTP requests permanently redirect to `https://mergeport.app`, preserving paths
and query strings. HTTPS `www` requests permanently redirect to the apex.
Both hostnames have A records with TTL 300. There is no AAAA record, since this
load balancer currently has only IPv4.

## Registrar and HTTPS

Set the domain's nameservers at the registrar to:

```text
ns-cloud-a1.googledomains.com
ns-cloud-a2.googledomains.com
ns-cloud-a3.googledomains.com
ns-cloud-a4.googledomains.com
```

[mergeport.app.zone](infra/mergeport.app.zone) is the exported BIND-format zone.
Cloud DNS is authoritative after registrar delegation propagates. Do not add
these NS records as ordinary records at the old DNS provider instead of changing
the registrar's nameserver delegation.

The Google-managed certificate can only become active after public DNS resolves
both names to the load balancer. Provisioning and edge propagation are
asynchronous; an existing Cloud DNS zone alone does not mean HTTPS is ready.

```sh
gcloud compute ssl-certificates describe mergeport-app-cert --global \
  --project=wouterdebie-personal --account="your-personal-google-account" \
  --format='yaml(managed)'
dig +short NS mergeport.app
dig +short A mergeport.app
curl -I https://mergeport.app
curl -I 'http://www.mergeport.app/?check=1'
```

## Validation

```sh
bash -n site/deploy.sh site/infra/provision.sh
gcloud compute url-maps validate --global --source=site/infra/https-map.yaml \
  --project=wouterdebie-personal --account="your-personal-google-account"
gcloud compute url-maps validate --global --source=site/infra/http-redirect.yaml \
  --project=wouterdebie-personal --account="your-personal-google-account"
```

Check the published page at desktop and narrow mobile sizes, in light and dark
mode. Confirm the free download and GitHub links, FAQ disclosure controls, icon
loading, and absence of horizontal overflow.

The social card is drawn in `assets/social.svg`; after editing it run
`(cd site/assets && rsvg-convert social.svg -o social.png)`. Icons are rendered
from `Resources/AppIcon.svg` with `rsvg-convert -w N -h N`.
