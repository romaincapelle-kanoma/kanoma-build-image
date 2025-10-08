packer {
  required_plugins {
    googlecompute = {
      version = "~> 1"
      source  = "github.com/hashicorp/googlecompute"
    }
    ansible = {
      version = "~> 1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}


variable "source_image_family" {
  type    = string
  default = "rhel-9"
}

variable "gcp-zone" {
  type    = string
  default = "europe-west9-c"
}

variable "prefix_name" {
  type    = string
  default = "kanoma"
}

variable "file_script" {
  type    = string
  default = "play_host_rhel_build.yml"
}

variable "project_id" {
  type    = string
}


locals {
  today = formatdate("YYYYMMDD-hhmm", timestamp())
}

source "googlecompute" "kanoma_image_rhel" {
  project_id              = var.project_id
  source_image_family     = var.source_image_family
  zone                    = var.gcp-zone
  machine_type            = "n2-standard-4"
  image_family            = "${var.prefix_name}-${var.source_image_family}"
  image_description       = "img ${var.source_image_family} kanoma"
  image_storage_locations = ["eu"]
  image_name              = "${var.prefix_name}-${var.source_image_family}-${local.today}"
  image_labels = {
    packer          = "true"
    compliant       = "true"
    src             = "${var.source_image_family}"
  }
  tags                        = ["build-packer"]
  ssh_username                = "packer"
  use_os_login                = true
  disk_size                   = 50
  enable_secure_boot          = true
  enable_vtpm                 = true
  enable_integrity_monitoring = true
  # network                     = "${var.network}"
  # subnetwork                  = "${var.subnetwork}"
  use_internal_ip             = true
  omit_external_ip            = true
  use_iap                     = true
}

build {
  sources = ["sources.googlecompute.iaas_image_rhel"]
  provisioner "ansible" {
    playbook_file   = "../../ansible/${var.file_script}"
    # galaxy_file     = "../../ansible/collections/requirements.yml"
    # galaxy_command  = "ansible-galaxy"
    extra_arguments = ["--scp-extra-args", "'-O'"]
  }
  post-processors {
    post-processor "manifest" {
      output = "manifest.json"
      strip_path = true
      custom_data = {
        image_name = "${var.prefix_name}-${var.source_image_family}-${local.today}"
      }
    }
  }
}