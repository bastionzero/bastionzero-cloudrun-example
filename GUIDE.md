# Guide

This guide is a walkthrough of how to use the
[`zli`](https://docs.bastionzero.com/docs/deployment/installing-the-zli) and
[BastionZero service
accounts](https://docs.bastionzero.com/docs/admin-guide/authentication/service-accounts-management)
to SSH into a Linux host from [Google Cloud
Run](https://cloud.google.com/run?hl=en). We use the example Node.js server,
[`Dockerfile`](./Dockerfile), and [`Terraform`](./main.tf) provided in this repo
to demonstrate this usecase. Please feel free to mix and match elements of these
components with your own custom integration to better fit your specific usecase.

**Note:** Terraform is not required to implement this Cloud Run usecase; it is
simply included in this example repo to make the guide easier to follow. 

## Before you begin

- You must be an administrator of your BastionZero organization in order to
  create a [BastionZero service account](https://docs.bastionzero.com/docs/admin-guide/authentication/service-accounts-management).
- Ensure the
  [`zli`](https://docs.bastionzero.com/docs/deployment/installing-the-zli) is
  installed on your machine as it is used to perform some of the one-time manual
  steps when creating the BastionZero service account.
- Ensure [`gcloud`](https://cloud.google.com/sdk/gcloud) is installed on your
  machine as it is used to submit a build of the example server to GCR. Don't
  forget to authorize the `gcloud` CLI (instructions found
  [here](https://cloud.google.com/sdk/docs/authorizing)).
- Ensure [`terraform`](https://developer.hashicorp.com/terraform/downloads) is
  installed on your machine as it is used to automate some of the infrastructure
  required to deploy the Cloud Run service.
- Ensure [`docker`](https://docs.docker.com/desktop/) is installed on your
  machine and is currently running.
- Setup Application Default Credentials (ADC) in order to configure the
  [`google` Terraform
  provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
  used in [`main.tf`](./main.tf): [`gcloud auth application-default
  login`](https://cloud.google.com/sdk/docs/authorizing#adc).
- Create a BastionZero [API
key](https://docs.bastionzero.com/docs/admin-guide/authorization#creating-an-api-key)
in order to configure the [`bastionzero` Terraform
provider](https://registry.terraform.io/providers/bastionzero/bastionzero/latest/docs)
used in [`main.tf`](./main.tf). Manage your API keys at the API key panel found
[here](https://cloud.bastionzero.com/admin/apikeys).
- Clone this repository and change your current working directory (`cwd`) to the
  root of the repo; the shell commands in this guide assume you have changed
  your `cwd` accordingly.

## Create a BastionZero service account (SA) via GCP

First, we'll create a BastionZero service account in your BastionZero
organization. We'll also download its associated public/private keypair and save
it, along with some other credentials, in Google Secret Manager for later use in
the Node.js server.

### Create the GCP service account

The Google Cloud Platform (GCP) provides a convenient way of creating the
public/private key pair and the JWKS URL, both of which are needed for setting
up your BastionZero service account.

Please follow steps 1-4 in this guide which detail how to create the SA on GCP:
https://docs.bastionzero.com/docs/admin-guide/authentication/service-accounts-management#google-cloud-service-account

At the end of the linked guide, you should have downloaded a `.json` file
(provider file) that contains your service account's credentials from GCP. Let's
rename this file to `provider-file.json` and place it in your current working
directory for convenience.

**Important:** Please keep note of the service account's email address as we'll
need it later. The email address should be displayed in the service account
creation screen after filling in the details. It can also be found in the table
of service accounts under "IAM" -> "Service Accounts" after creation. It should
look something like this:
`<service-account-id>@<gcp-project-id>.iam.gserviceaccount.com`

### Create the BastionZero service account

Next, let's use these credentials to create the BastionZero service account in
your BastionZero organization:

```sh
zli login
zli service-account create provider-file.json
```

The result of the `zli service-account create` command will be a
`bzero-credentials.json` file created in your current working directory.

### Store credentials in Google Secret Manager

To finish up this section, we'll upload both the `provider-file.json` file and
`bzero-credentials.json` file as secrets in Google Secret Manager. Open up the
Secret Manager on the GCP Console:
https://console.cloud.google.com/security/secret-manager

#### Secret #1: `cloudrun-example-sa-provider-cred`

1) Click "Create Secret".
2) In the name field, enter: `cloudrun-example-sa-provider-cred`. You can use a
   different name, but you'll have to input your chosen secret name when we
   apply the Terraform.
3) Click "Secret value" -> Upload file -> "Browse" and upload the
   `provider-file.json` file as the value for this secret.
4) Click the "Create Secret" button at the bottom to apply your selections and
   create the secret.

#### Secret #2: `cloudrun-example-sa-bzero-cred`

Let's create one more secret. Follow the same instructions in the section above,
except this secret's name should be `cloudrun-example-sa-bzero-cred` and in step
#3, you should upload the `bzero-credentials.json` file instead.

## Upload example container image to GCR

Next, we'll use the `gcloud` CLI to submit a build of the example Node.js server
to GCR; our example Cloud Run service will run using this image.

Before uploading, let's explain some of the components in both the `Dockerfile`
and the application code (`*.ts` files).

### `Dockerfile`

The [`Dockerfile`](./Dockerfile) defines how to build the container image and
entrypoint for the Cloud Run service application.

#### Install `zli` as a dependency

The following section is the code that installs the `zli` as a system package
dependency in the container. This step is required so the Node.js server can use
the `zli` to SSH into a BastionZero-secured Linux host:

https://github.com/bastionzero/bastionzero-cloudrun-example/blob/fa3100807fdc86f3815c09dca0d9d4e87a5f934e/Dockerfile#L6-L12

#### Install `ssh` as a dependency

This section installs the `openssh-client` so that the Node.js server can
execute `ssh`. It also creates an empty `~/.ssh/config` file which the `zli`
updates to store config information related to connecting to your target over
SSH:

https://github.com/bastionzero/bastionzero-cloudrun-example/blob/fa3100807fdc86f3815c09dca0d9d4e87a5f934e/Dockerfile#L14-L17

### `app.ts`

Most of the core logic of the Node.js server can be found in
[`app.ts`](./app.ts). Let's go over some parts of the code.

#### Fetch secrets from Google Secret Manager

We use the
[`@google-cloud/secret-manager`](https://www.npmjs.com/package/@google-cloud/secret-manager)
npm package to fetch and store the required service account credentials in
memory:

https://github.com/bastionzero/bastionzero-cloudrun-example/blob/fa3100807fdc86f3815c09dca0d9d4e87a5f934e/app.ts#L28-L46

#### Use service account credentials to login via the `zli` programmatically

We use `zli service-account login` to perform a headless authentication to the
BastionZero platform:

https://github.com/bastionzero/bastionzero-cloudrun-example/blob/fa3100807fdc86f3815c09dca0d9d4e87a5f934e/app.ts#L63-L80

Using BastionZero service accounts prevents the need to perform a
user-interactive login session with your identity provider (`zli login`).

#### SSH

We define a `/ssh` HTTP endpoint that performs the SSH logic to run an arbitrary
command on a Linux host secured by BastionZero:

https://github.com/bastionzero/bastionzero-cloudrun-example/blob/fa3100807fdc86f3815c09dca0d9d4e87a5f934e/app.ts#L108-L152

Some steps are cached to speed-up subsequent calls to `/ssh` if the same
container is still running.

- `zliServiceAccountLogin()` logs in to BastionZero using the service account
  credentials. See the previous section for more details.
- `zli generate sshConfig` updates the `~/.ssh/config` file with a list of
  BastionZero targets that the logged-in BastionZero service account has policy
  access to connect to.
- `ssh -F ...` performs the parsed command from the query string against the
  Linux host via SSH.

### Upload to GCR

Run the following command from the root directory of this repository to upload
an image of this example application to GCR:

```bash
gcloud builds submit --tag gcr.io/<project-id>/bastionzero-cloudrun-example
```

Please replace `<project-id>` with the GCP project ID of your choice.

## Apply Terraform to deploy remaining infrastructure

With all the previous steps completed, we're now ready to perform the remaining
infrastructure tasks to get the example Cloud Run service running. This step is
easy as we'll just use the example [`main.tf`](./main.tf) Terraform file to
apply these infrastructure changes.

### Install the Terraform providers

We use the following providers in [`main.tf`](./main.tf):
- The [`google` Terraform
  provider](https://registry.terraform.io/providers/hashicorp/google/latest/docs)
  is used to deploy the Cloud Run service and create its service account to give
  the example application access to the secrets we stored earlier in Google
  Secret Manager.
- The [`docker` Terraform
  provider](https://registry.terraform.io/providers/kreuzwerker/docker/latest/docs)
  is used to find the digest hash of the image we uploaded to GCR in the
  previous [step](#upload-to-gcr).
- The [`bastionzero` Terraform
provider](https://registry.terraform.io/providers/bastionzero/bastionzero/latest/docs)
is used to create a [target connect
policy](https://docs.bastionzero.com/docs/admin-guide/authorization#target-access)
that gives [the BastionZero service
account](#create-the-bastionzero-service-account) access to SSH into your
BastionZero targets.

Run the following command to install the providers used by `main.tf`:

```bash
terraform init
```

### Configure the Terraform providers

The `google` Terraform provider should automatically be configured if you have
setup your ADC as described in the [first section](#before-you-begin).

The `docker` Terraform provider has no additional configuration. However, please
ensure `docker` is running before proceeding.

To configure the `bastionzero` Terraform provider, you'll need to export an
environment variable that holds the API secret of your API key you created
earlier.

Set the `BASTIONZERO_API_SECRET` environment variable to the API key's secret
that you created in the [first section](#before-you-begin):

```bash
export BASTIONZERO_API_SECRET=api-secret
```

### Apply the Terraform

We're now ready to run `terraform apply` to apply the remaining infrastructure
and deploy the Cloud Run service.

Before applying, please read over the [`main.tf`](./main.tf) file and the
comments to better understand what it is doing.

Here is a quick summary:
- A new [GCP service
  account](https://github.com/bastionzero/bastionzero-cloudrun-example/blob/ea74090fa6d56422d7b2358d01855296f2516780/main.tf#L81-L97)
  is created. This service account is given minimal permissions, namely only
  read access to the secrets created
  [earlier](#store-credentials-in-google-secret-manager).
- The [Cloud Run
  service](https://github.com/bastionzero/bastionzero-cloudrun-example/blob/ea74090fa6d56422d7b2358d01855296f2516780/main.tf#L116-L139)
  is created. It is configured to run with the least privileged service account
  created in the previous step. It is also configured to run using the image we
  [uploaded to GCR](#upload-to-gcr).
- A [BastionZero target connect
  policy](https://github.com/bastionzero/bastionzero-cloudrun-example/blob/ea74090fa6d56422d7b2358d01855296f2516780/main.tf#L141-L167)
  is created which gives [the BastionZero service
  account](#create-the-bastionzero-service-account) SSH access (as the `root`
  user) to targets in the `Default` and `AWS` environments in your BastionZero
  organization. Please modify accordingly to better fit your infrastructure
  requirements (e.g. use different
  [`target_user`](https://github.com/bastionzero/bastionzero-cloudrun-example/blob/ea74090fa6d56422d7b2358d01855296f2516780/main.tf#L164)
  than `root` or other
  [`envs`](https://github.com/bastionzero/bastionzero-cloudrun-example/blob/ea74090fa6d56422d7b2358d01855296f2516780/main.tf#L149)
  than `Default` and `AWS`).

Run the following command to apply the remaining infrastructure via Terraform:

```bash
terraform apply
```

Terraform will prompt you to fill in some input variables:
- `var.bastionzero_service_account_email`: Enter in the email of the service
  account we created in the [beginning](#create-the-gcp-service-account) of this
  guide.
- `var.project_id`: Enter in the same `<project-id>` you selected when [building
  the image](#upload-to-gcr). This same project will contain the Cloud Run
  service that we're about to deploy.

If you picked different secret names than the ones described
[earlier](#store-credentials-in-google-secret-manager), then you will also need
to [override the
defaults](https://developer.hashicorp.com/terraform/language/values/variables#variables-on-the-command-line)
and pass different values for `var.provider_creds_file_secret_name` and
`var.bzero_creds_file_secret_name`.

Review the returned Terraform plan and type in "yes" and press enter to apply
the plan.

## Demo via proxy

Let's demo the example by proxying the Cloud Run service to `localhost` and
authenticating as the active account (i.e. the account you are logged in as via
`gcloud`). This step is required because by default the Cloud Run service
requires authenticated access in order to invoke its public endpoints. See more
details about Cloud Run authentication
[here](https://cloud.google.com/run/docs/authenticating/overview).

Run the following command to start the proxy on `localhost`:

```bash
gcloud run services proxy bzero-cloudrun
```

There should now be a proxy server running on `localhost:8080` that proxies your
requests to the Cloud Run service.

- [`/`](http://127.0.0.1:8080/): Returns the version of the `zli` executable
installed on the container.
- [`/ssh?host=example-target`](http://127.0.0.1:8080/ssh?host=example-target):
  Executes the [default
  command](https://github.com/bastionzero/bastionzero-cloudrun-example/blob/cff6437444c355c55de7dc7263a123f5a7d5f4bc/app.ts#L121)
  against the target `example-target`. In this example, `ssh` logins as `root`
  to execute the command.
- [`/ssh?host=example-target&cmd=whoami`](http://127.0.0.1:8080/ssh?host=example-target&cmd=whoami):
  Executes the `whoami` command against the target `example-target`. In this
  example, `ssh` logins as `root` to execute the command.
- [`/ssh?host=example-target&cmd=whoami&user=foo`](http://127.0.0.1:8080/ssh?host=example-target&cmd=whoami&user=foo):
  Executes the `whoami` command against the target `example-target`. In this
  example, `ssh` logins as `foo` to execute the command. You may receive an
  error if the service account does not have BastionZero policy access to SSH as
  the `foo` user, or if the user `foo` does not exist on the Linux host.

## Cleanup

Below are some optional cleanup steps:

- Run `terraform destroy` to destroy the example Cloud Run service and other
infrastructure created by Terraform.
- Delete the example image `bastionzero-cloudrun-example` from your project's
  GCR: https://console.cloud.google.com/gcr/images/.
- Delete the secrets `cloudrun-example-sa-provider-cred` and
  `cloudrun-example-sa-bzero-cred` from Google Secret Manager:
  https://console.cloud.google.com/security/secret-manager.
- Disable the [service account](#create-the-bastionzero-service-account) in your BastionZero organization: https://cloud.bastionzero.com/admin/subjects
- Delete the [service account](#create-the-gcp-service-account) from GCP:
  https://console.cloud.google.com/iam-admin/serviceaccounts.
- Delete the [API key](#before-you-begin) in your BastionZero organization:
  https://cloud.bastionzero.com/admin/apikeys.