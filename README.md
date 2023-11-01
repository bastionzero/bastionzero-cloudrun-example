# bastionzero-cloudrun-example

An example repo demonstrating how to use the
[`zli`](https://docs.bastionzero.com/docs/deployment/installing-the-zli) and
[BastionZero service
accounts](https://docs.bastionzero.com/docs/admin-guide/authentication/service-accounts-management)
to SSH into a Linux host from [Google Cloud
Run](https://cloud.google.com/run?hl=en).

This repo contains an example Node.js server that uses the `zli` and `ssh` to
execute an arbitrary command on a BastionZero-secured Linux host. The included
[`Dockerfile`](./Dockerfile) and [`Terraform`](./main.tf) package this server as
a [Cloud Run
service](https://cloud.google.com/run/docs/overview/what-is-cloud-run#services)
and create most of the required infrastructure (on GCP and BastionZero) to demo
this example server.

Follow along the guide here: [`GUIDE.md`](./GUIDE.md). The document highlights
specific components of this repo and provides the commands required to deploy
and run this example in Cloud Run.

**Note:** The code provided in this repository is _example_ code; please use
this repository as a reference point to mix with your own code and custom
integrations.