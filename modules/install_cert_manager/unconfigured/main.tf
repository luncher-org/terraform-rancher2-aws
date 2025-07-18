locals {
  cert_manager_version = var.cert_manager_version
  project_cert_key_id  = var.project_cert_key_id
  project_cert_name    = var.project_cert_name
}

data "aws_iam_server_certificate" "project_cert" {
  name = local.project_cert_name
}

data "aws_secretsmanager_secret_version" "project_cert_key" {
  secret_id = local.project_cert_key_id
}

resource "time_sleep" "settle_before_cert_manager" {
  create_duration = "30s"
}

# uses kubectl to idempotentenly create cattle-system namespace
resource "terraform_data" "cattle-system" {
  depends_on = [
    time_sleep.settle_before_cert_manager,
  ]
  provisioner "local-exec" {
    command = <<-EOT
      kubectl get namespace cattle-system || kubectl create namespace cattle-system
    EOT
  }
  provisioner "local-exec" {
    command = <<-EOT
    kubectl get namespace "cattle-system" -o json  \
     | tr -d "\n" \
     | sed "s/\"finalizers\": \[[^]]\+\]/\"finalizers\": []/"   \
     | kubectl replace --raw /api/v1/namespaces/cattle-system/finalize -f -
    EOT
    when    = destroy
  }
  provisioner "local-exec" {
    command = <<-EOT
      sleep 15
    EOT
    when    = destroy
  }
}

resource "kubernetes_secret" "tls_rancher_ingress" {
  depends_on = [
    time_sleep.settle_before_cert_manager,
    terraform_data.cattle-system,
  ]
  metadata {
    name      = "tls-rancher-ingress"
    namespace = "cattle-system"
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = <<-EOT
      ${data.aws_iam_server_certificate.project_cert.certificate_body}
      ${data.aws_iam_server_certificate.project_cert.certificate_chain}
    EOT
    "tls.key" = data.aws_secretsmanager_secret_version.project_cert_key.secret_string,
    "tls-ca"  = data.aws_iam_server_certificate.project_cert.certificate_chain,
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_secret" "tls_rancher_ca" {
  depends_on = [
    time_sleep.settle_before_cert_manager,
    terraform_data.cattle-system,
    kubernetes_secret.tls_rancher_ingress,
  ]
  metadata {
    name      = "tls-ca"
    namespace = "cattle-system"
  }
  type = "generic"
  data = {
    "cacerts.pem" = data.aws_iam_server_certificate.project_cert.certificate_chain,
  }
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
    ]
  }
}

# https://github.com/cert-manager/cert-manager/blob/master/deploy/charts/cert-manager/values.yaml
resource "helm_release" "cert_manager_unconfigured" {
  depends_on = [
    time_sleep.settle_before_cert_manager,
    terraform_data.cattle-system,
    kubernetes_secret.tls_rancher_ingress,
    kubernetes_secret.tls_rancher_ca,
  ]
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = local.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = false
  wait_for_jobs    = false
  force_update     = true
  timeout          = 1200 # 20m

  set {
    name  = "installCRDs"
    value = "true"
  }
}
