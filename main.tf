# Google Provider Configuration
provider "google" {
  credentials = var.gcp_credentials
  project     = var.project_id
  region      = "us-central1"
}
 
# Create a service account for GKE account
resource "google_service_account" "gke_service_account" {
  account_id   = "gke-cluster-sa"
  display_name = "GKE Cluster Service Account"
}

# Google Kubernetes Engine (GKE) cluster
resource "google_container_cluster" "timeapi_cluster1" {
  name     = "timeapi-cluster1"
  location = "us-central1"

  initial_node_count = 1
  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 75
    service_account = google_service_account.gke_service_account.email
  }
}

# Assign IAM roles to the service account
resource "google_project_iam_member" "gke_cluster_admin" {
  project = var.project_id
  role    = "roles/container.clusterAdmin"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
}

resource "google_project_iam_member" "gke_compute_admin" {
  project = var.project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
}

resource "google_project_iam_member" "gke_iam_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.gke_service_account.email}"
}

# Data source to check for an existing VPC network
data "google_compute_network" "existing_vpc_network" {
  name    = "vpc-network"
  project  = var.project_id
}

# Create a VPC network only if it doesn't exist
resource "google_compute_network" "vpc_network" {
  count = length(data.google_compute_network.existing_vpc_network.id) == 0 ? 1 : 0
  name  = "vpc-network"
}

# Data source to check for an existing Subnetwork
data "google_compute_subnetwork" "existing_subnet" {
  name    = "timeapisubnet"
  region  = "us-central1"
  project = var.project_id
}

# Create a Subnetwork only if it doesn't exist
resource "google_compute_subnetwork" "timeapisubnet" {
  count         = length(data.google_compute_subnetwork.existing_subnet.id) == 0 ? 1 : 0
  name          = "timeapisubnet"
  network       = google_compute_network.vpc_network[0].id
  ip_cidr_range = "10.0.0.0/16"
  region        = "us-central1"
}

# Create a Firewall Rule
resource "google_compute_firewall" "allow-internal" {
  count   = length(data.google_compute_network.existing_vpc_network.id) > 0 || google_compute_network.vpc_network.*.id != [] ? 1 : 0
  name    = "allow-internal"
  network = length(data.google_compute_network.existing_vpc_network.id) > 0 ? data.google_compute_network.existing_vpc_network.id : google_compute_network.vpc_network[0].id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.0.0.0/16"]
}

# Create a NAT Router only if it doesn't exist
resource "google_compute_router" "nat_router" {
  count   = length(data.google_compute_router.existing_nat_router.id) == 0 ? 1 : 0
  name    = "nat-router"
  network = length(data.google_compute_network.existing_vpc_network.id) > 0 ? data.google_compute_network.existing_vpc_network.id : google_compute_network.vpc_network[0].id
  region  = "us-central1"
}

# Data source to check for an existing NAT Router
data "google_compute_router" "existing_nat_router" {
  name    = "nat-router"
  region  = "us-central1"
  project = var.project_id
  network = length(data.google_compute_network.existing_vpc_network.id) > 0 ? data.google_compute_network.existing_vpc_network.id : google_compute_network.vpc_network[0].id
}

# Check if the NAT Gateway already exists
data "google_compute_router_nat" "existing_nat_gateway" {
  name   = "nat-gateway"
  router = data.google_compute_router.existing_nat_router.name
  region = "us-central1"
  project = var.project_id
}

# Create a NAT Gateway only if it doesn't exist
resource "google_compute_router_nat" "nat_gateway" {
  count = length(data.google_compute_router_nat.existing_nat_gateway.id) == 0 ? 1 : 0
  name  = "nat-gateway"
  router = google_compute_router.nat_router[0].name
  region = google_compute_router.nat_router[0].region
  nat_ip_allocate_option = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Kubernetes Namespace
resource "kubernetes_namespace" "timeapi_ns" {
  metadata {
    name = "timeapi-namespace"
  }
}

# Kubernetes Deployment
resource "kubernetes_deployment" "timeapi_deployment" {
  metadata {
    name      = "timeapi-deployment"
    namespace = kubernetes_namespace.timeapi_ns.metadata[0].name
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
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}

# Kubernetes Service
resource "kubernetes_service" "my_api_service" {
  metadata {
    name      = "my-api-service"
    namespace = kubernetes_namespace.timeapi_ns.metadata[0].name
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
    name      = "timeapi-ingress"
    namespace = kubernetes_namespace.timeapi_ns.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/"
    }
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

    tls {
      secret_name = "timeapi-tls"
    }
  }
}
