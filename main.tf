provider "google" {
  credentials = jsondecode(var.gcp_credentials)
  project     = "time-api-1"
  region      = "us-central1"
}

variable "gcp_credentials" {
  description = "The JSON credentials for GCP"
  type        = string
}
variable "project_id" {
  description = "The GCP Project ID"
  type        = string

# Google Kubernetes Engine (GKE) cluster
resource "google_container_cluster" "timeapi_cluster" {
  name     = "timeapi-cluster"
  location = "us-central1"

  initial_node_count = 1

  node_config {
    machine_type = "e2-medium"
    service_account = google_service_account.gke_service_account.email
  }
}

# Create a service account for GKE
resource "google_service_account" "gke_service_account" {
  account_id   = "gke-cluster-sa"
  display_name = "GKE Cluster Service Account"
}

# Assign IAM roles to the service account
resource "google_project_iam_member" "gke_cluster_admin" {
  project = "time-api-1"
  role    = "roles/container.clusterAdmin"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
}

resource "google_project_iam_member" "gke_compute_admin" {
  project = "time-api-1"
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
}

resource "google_project_iam_member" "gke_iam_service_account_user" {
  project = "time-api-1"
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
}

# Create a VPC
resource "google_compute_network" "vpc_network" {
  name = "vpc-network"
}

# Create a Subnetwork
resource "google_compute_subnetwork" "timeapisubnet_main" {
  name          = "timeapisubnet-main"
  network       = google_compute_network.vpc_network.id
  ip_cidr_range = "10.0.0.0/16"
  region        = "us-central1"
}

# Create a Firewall Rule to allow internal/secure communication
resource "google_compute_firewall" "allow-internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.0.0.0/16"]
}

# Create NAT Gateway
resource "google_compute_router" "nat_router" {
  name    = "nat-router"
  network = google_compute_network.vpc_network.id
  region  = "us-central1"
}

resource "google_compute_router_nat" "nat_gateway" {
  name                               = "nat-gateway"
  router                             = google_compute_router.nat_router.name
  region                             = google_compute_router.nat_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Kubernetes Namespace
resource "kubernetes_namespace" "example" {
  metadata {
    name = "example-namespace"
  }
}

# Kubernetes Deployment
resource "kubernetes_deployment" "timeapi_deployment" {
  metadata {
    name      = "timeapi-deployment"
    namespace = kubernetes_namespace.example.metadata[0].name
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "my-api"
      }
    }

    template {
      metadata {
        labels = {
          app = "my-api"
        }
      }

      spec {
        container {
          image = "gcr.io/${var.project_id}/timeapi:latest"
          name  = "time_api_container"

        }
      }
    }
  }
}

# Kubernetes Service
resource "kubernetes_service" "my_api_service" {
  metadata {
    name      = "my-api-service"
    namespace = kubernetes_namespace.example.metadata[0].name
  }

  spec {
    selector = {
      app = "my-api"
    }

    port {
      port        = 80
      target_port = 8080
    }
  }
}

# Kubernetes Ingress
resource "kubernetes_ingress" "timeapi_ingress" {
  metadata {
    name      = "timeapi_ingress"
    namespace = kubernetes_namespace.example.metadata[0].name
  }

  spec {
    rule {
      http {
        path {
          path = "/time"
          backend {
            service_name = kubernetes_service.my_api_service.metadata[0].name
            service_port = 80
          }
        }
      }
    }
  }
}