terraform {
  required_providers {
    signalfx = {
      source  = "splunk-terraform/signalfx"
      version = "~> 9.0"
    }
  }

  # Uncomment to store state remotely (recommended for teams)
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "hyperv-o11y-accelerator/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "signalfx" {
  auth_token = var.splunk_access_token
  api_url    = "https://api.${var.splunk_realm}.signalfx.com"
}

resource "signalfx_dashboard_group" "hyperv" {
  name        = "Hyper-V Monitoring"
  description = "Hyper-V hypervisor + VM monitoring accelerator (see repo README for architecture/limitations)"
}
