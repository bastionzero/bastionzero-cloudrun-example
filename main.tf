terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.4.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.0.2"
    }
    bastionzero = {
      source  = "bastionzero/bastionzero"
      version = "0.2.0"
    }
  }
  required_version = "~> 1.1"
}

variable "project_id" {
  type        = string
  description = "GCP project ID where all GCP resources are created/read from"
  nullable    = false
}

variable "image_name" {
  type        = string
  description = "Image name to pull from Google Container Registry. This is the image used by the CloudRun service."
  nullable    = false
  default     = "bastionzero-cloudrun-example"
}

variable "provider_creds_file_secret_name" {
  type        = string
  description = "Name of GCP secret that contains the service account provider credentials (provider-file.json)."
  nullable    = false
  default     = "cloudrun-example-sa-provider-cred"
}

variable "bzero_creds_file_secret_name" {
  type        = string
  description = "Name of GCP secret that contains the service account Bzero credentials (bzeroCreds.json)."
  nullable    = false
  default     = "cloudrun-example-sa-bzero-cred"
}

variable "bastionzero_service_account_email" {
  type        = string
  description = "Email of the BastionZero service account to grant permission to SSH into your Linux host."
  nullable    = false
}

provider "bastionzero" {}
provider "docker" {
  registry_auth {
    address  = "gcr.io"
    username = "oauth2accesstoken"
    password = data.google_client_config.default.access_token
  }
}
provider "google" {
  project = var.project_id
  region  = "us-east1"
}

data "google_client_config" "default" {}

# This secret should contain the provider credentials file
data "google_secret_manager_secret" "provider_creds_file_secret" {
  secret_id = var.provider_creds_file_secret_name
}
# This secret should contain the bzero credentials file
data "google_secret_manager_secret" "bzero_creds_file_secret" {
  secret_id = var.bzero_creds_file_secret_name
}
locals {
  # Dictionary of secrets used by the CloudRun service
  secret_ids = {
    provider_cred = data.google_secret_manager_secret.provider_creds_file_secret.secret_id
    bzero_cred    = data.google_secret_manager_secret.bzero_creds_file_secret.secret_id
  }
}

# Create SA and add IAM bindings to give the SA minimal permissions required to
# run the CloudRun service
resource "google_service_account" "bzero_cloudrun_sa" {
  account_id   = "bzero-cloudrun-sa"
  display_name = "BastionZero CloudRun Service Account Example"
  description  = "The service account used by the example CloudRun service"
}
# Grant the secretAcccessor role to the cloudrun SA for the secrets needed to
# run the CloudRun service
resource "google_secret_manager_secret_iam_member" "access_secret_bindings" {
  for_each  = local.secret_ids
  project   = var.project_id
  secret_id = each.value
  # This role has permission to access a secret
  role   = "roles/secretmanager.secretAccessor"
  member = google_service_account.bzero_cloudrun_sa.member
}

# Get digest of `latest` tag for custom image hosted on GCR
#
# Run `gcloud builds submit --tag gcr.io/<project_id>/<image_name>` to submit
# new build to the GCR, then run `terraform apply` to update the CloudRun
# service to use the new build
data "google_container_registry_image" "example_image_tagged" {
  name = var.image_name
  tag  = "latest"
}
data "docker_registry_image" "example_image" {
  name = data.google_container_registry_image.example_image_tagged.image_url
}
data "google_container_registry_image" "example_image" {
  name   = var.image_name
  digest = data.docker_registry_image.example_image.sha256_digest
}

# Define the CloudRun service
resource "google_cloud_run_v2_service" "bzero_cloudrun" {
  name        = "bzero-cloudrun"
  description = "BastionZero CloudRun example"
  location    = "us-east1"
  # Require the secret bindings for this service's SA to be created first
  depends_on = [google_secret_manager_secret_iam_member.access_secret_bindings]

  template {
    containers {
      image = data.google_container_registry_image.example_image.image_url
      env {
        name  = "PROVIDER_FILE_SECRET_NAME"
        value = "${data.google_secret_manager_secret.provider_creds_file_secret.name}/versions/latest"
      }
      env {
        name  = "BZERO_FILE_SECRET_NAME"
        value = "${data.google_secret_manager_secret.bzero_creds_file_secret.name}/versions/latest"
      }
    }

    service_account = google_service_account.bzero_cloudrun_sa.email
  }
}

# Create a target connect policy that permits the BastionZero SA user permission
# to SSH
data "bastionzero_service_accounts" "sa" {}
data "bastionzero_environments" "e" {}
locals {
  # Define, by email address, the SAs to add to the policy
  service_accounts = [var.bastionzero_service_account_email]
  # Define, by name, the environments to add to the policy
  envs = ["Default", "AWS"]
}
resource "bastionzero_targetconnect_policy" "example" {
  name        = "bzero-cloudrun-ssh-policy"
  description = "Policy managed by Terraform."
  subjects = [
    for each in data.bastionzero_service_accounts.sa.service_accounts
    : { id = each.id, type = each.type } if contains(local.service_accounts, each.email)
  ]
  environments = [
    for each in data.bastionzero_environments.e.environments
    : each.id if contains(local.envs, each.name)
  ]

  # Permit access as "root"
  target_users = ["root"]
  # Allow SSH
  verbs = ["Tunnel"]
}
