# Controllers submodule

Installs the optional cluster components the root `terraform-google-n8n`
module manages beyond GKE's native controllers: the KEDA operator (used to
scale n8n worker pods on Redis queue depth) and an explicit balanced-PD
`StorageClass` for any stateful workload run beside n8n.

GKE's native ingress controller, metrics server, cluster autoscaler, and PD
CSI driver are prerequisites this submodule assumes already exist; it does
not install them.

## Usage

The root module invokes this submodule by default (see `../../controllers.tf`);
most callers never need to reference it directly.

Use it directly when composing KEDA and the StorageClass with your own,
separately managed n8n deployment (see
[`examples/direct-use`](./examples/direct-use)). In that case, order your own
n8n release after this module so KEDA exists before any `ScaledObject` it
creates, and so `terraform destroy` removes your n8n release (and its
`ScaledObject`s) before KEDA is uninstalled:

```hcl
module "controllers" {
  source = "github.com/n8n-io/terraform-google-n8n//modules/controllers"

  install_keda                     = true
  create_pd_balanced_storage_class = true
}

resource "helm_release" "n8n" {
  # ...
  depends_on = [module.controllers]
}
```

## Existing KEDA

Set `install_keda = false` to use a KEDA operator and CRDs that already exist
on the cluster. This submodule does not attempt to detect or validate that
installation; the caller is responsible for ensuring it is compatible with
whatever `ScaledObject`s it (or the root module) creates.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.keda](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_storage_class_v1.pd_balanced](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_common_labels"></a> [common\_labels](#input\_common\_labels) | Common labels merged into the StorageClass this submodule creates. Ignored when create\_pd\_balanced\_storage\_class = false. | `map(string)` | `{}` | no |
| <a name="input_create_pd_balanced_storage_class"></a> [create\_pd\_balanced\_storage\_class](#input\_create\_pd\_balanced\_storage\_class) | When true (the default), this submodule creates an explicit pd-balanced StorageClass for stateful workloads that run beside n8n (n8n itself is stateless). Set to false to omit it, e.g. when the caller already defines an equivalent StorageClass. | `bool` | `true` | no |
| <a name="input_install_keda"></a> [install\_keda](#input\_install\_keda) | When true (the default), this submodule installs and manages the KEDA Helm release. Set to false to use an existing KEDA installation (a compatible operator and CRDs already present on the cluster); no KEDA Helm release is rendered. | `bool` | `true` | no |
| <a name="input_keda_chart_repository"></a> [keda\_chart\_repository](#input\_keda\_chart\_repository) | Helm chart repository KEDA is installed from. Accepts an HTTPS chart-repository URL or an OCI registry reference (oci://...), so a private mirror can replace the public kedacore charts. Ignored when install\_keda = false. | `string` | `"https://kedacore.github.io/charts"` | no |
| <a name="input_keda_chart_version"></a> [keda\_chart\_version](#input\_keda\_chart\_version) | KEDA Helm chart version to deploy. Pinned so every apply installs the same operator version; bump deliberately and re-run the test suite rather than floating to latest. Must be an exact semantic version. Ignored when install\_keda = false. | `string` | `"2.20.1"` | no |
| <a name="input_keda_helm_timeout"></a> [keda\_helm\_timeout](#input\_keda\_helm\_timeout) | Seconds Terraform waits for the KEDA Helm release to converge. Ignored when install\_keda = false. | `number` | `300` | no |
| <a name="input_keda_namespace"></a> [keda\_namespace](#input\_keda\_namespace) | Kubernetes namespace KEDA is installed into. Created automatically by the Helm release. Ignored when install\_keda = false. | `string` | `"keda"` | no |
| <a name="input_pd_balanced_storage_class_name"></a> [pd\_balanced\_storage\_class\_name](#input\_pd\_balanced\_storage\_class\_name) | Name of the pd-balanced StorageClass. Ignored when create\_pd\_balanced\_storage\_class = false. | `string` | `"n8n-pd-balanced"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_keda_chart_version"></a> [keda\_chart\_version](#output\_keda\_chart\_version) | KEDA Helm chart version installed, or null when install\_keda = false. |
| <a name="output_keda_installed"></a> [keda\_installed](#output\_keda\_installed) | Whether this submodule installed the KEDA Helm release (mirrors var.install\_keda). |
| <a name="output_keda_namespace"></a> [keda\_namespace](#output\_keda\_namespace) | Namespace KEDA is installed into, or null when install\_keda = false. |
| <a name="output_keda_release_name"></a> [keda\_release\_name](#output\_keda\_release\_name) | Name of the KEDA Helm release, or null when install\_keda = false. |
| <a name="output_pd_balanced_storage_class_name"></a> [pd\_balanced\_storage\_class\_name](#output\_pd\_balanced\_storage\_class\_name) | Name of the pd-balanced StorageClass, or null when create\_pd\_balanced\_storage\_class = false. |
<!-- END_TF_DOCS -->
