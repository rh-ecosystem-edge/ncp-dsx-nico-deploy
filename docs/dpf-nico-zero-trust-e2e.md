# OpenShift DPF Zero Trust with NICo

This runbook coordinates the DPF Zero Trust automation with the NICo deployment in this repository. It is for a management OpenShift cluster where DPF runs, NICo creates the DPU deployment and workload resources, and DPF provisions the DPU and creates the HostedCluster.

## Ownership and prerequisites

Use the [DPF NICo integration change](https://github.com/rh-ecosystem-edge/openshift-dpf/pull/510) with `DPF_DEPLOYMENT_MODE=zero-trust` and `NICO_ENABLED=true`. In this mode, DPF installs its platform and HCP prerequisites but leaves NICo-owned DPU inventory and workload resources to NICo. Configure NICo with external DPF enabled and `[dpf].enabled=true`; NICo must create the `DPUDeployment` before DPF creates the HostedCluster. DPF controllers then provision the DPU and reconcile NICo's DPF resources.

Before running the coordinated target, prepare:

- A management-cluster kubeconfig and the HostedCluster name and kubeconfig path.
- A DPF automation checkout containing the NICo integration change and its required protected `.env` settings, pull secrets, and reachable CoreOS BFB endpoint.
- NICo cloud and site values, including the site name, matching `DPUDeployment` name, DPU/host BMC inventory, and service image settings.
- A reachable DPF Helm chart repository with its TLS configuration. The repository and its credentials are site infrastructure; this target does not create them.
- The RHCOS-compatible `nico-dpu-agent` chart from [infra-controller PR #8798](https://github.com/dsx-ai-factory/infra-controller/pull/8798). Until that change is merged and vendored, set `NICO_DPU_AGENT_CHART_SOURCE` to the chart directory from its branch.

Keep credentials in the DPF automation's protected environment or secret store. Do not commit `.env`, kubeconfigs, BMC passwords, pull secrets, or generated chart repository data.

## Run and resume

First render the plan. `DRY_RUN=true` validates local inputs and prints the stages; it does not contact the cluster or prove readiness.

```bash
make deploy-dpf-nico-zt DRY_RUN=true \
  DPF_AUTOMATION_DIR=/path/to/openshift-dpf \
  SITE=lab SITE_NAME=lab \
  NICO_DPU_DEPLOYMENT_NAME=nico-deployment-v2 \
  HOSTED_CLUSTER_NAME=doca \
  KUBECONFIG=/path/to/management-kubeconfig \
  HOSTED_KUBECONFIG=/path/to/hosted-kubeconfig \
  NICO_DPU_AGENT_CHART_SOURCE=/path/to/infra-controller/bluefield/charts/nico-dpu-agent
```

After reviewing the plan and site values, run the same command without `DRY_RUN=true`. The `all` stage runs DPF platform setup, NICo cloud/site/site-agent deployment, waits for NICo's `DPUDeployment`, creates the HostedCluster, applies DPF's hosted-cluster authorization, publishes the compatible chart, configures the LLDP sidecar's RHCOS library path, and checks DPU and HostedCluster readiness.

For recovery, rerun one stage at a time with `STAGE=dpf`, `STAGE=nico`, or `STAGE=hosted`. Use `STAGE=verify` for read-only readiness checks. Do not rerun the full sequence just to verify a deployment.

## RHCOS LLDP sidecar compatibility

The DPU-agent chart change is optional and preserves existing defaults. When `lldpSidecar.hostLibraryPath` is set, the chart mounts that host directory read-only at `/host/lib64` and sets `LD_LIBRARY_PATH` for the LLDP sidecar. `/usr/lib64` is the tested path on the lab's RHCOS DPU image; change `NICO_DPU_AGENT_HOST_LIBRARY_PATH` only after verifying the target image's library directory. The DPF integration target publishes the chart to the site's existing chart repository before applying DPU service configuration, then patches the NICo-created `DPUServiceConfiguration` so it also works with NICo API versions that do not propagate `extra_helm_values`.

The chart publisher updates the chart repository ConfigMap and restarts its repository Deployment. It requires the repository, service, TLS material, and permissions to exist already. It is not a replacement for an approved production chart distribution process.

## Manual gates and troubleshooting

- **External reboot:** DPF may set `provisioning.dpu.nvidia.com/dpunode-external-reboot-required=true`. The target reports this gate and stops; an operator must reboot the named host, wait for it to return, and clear the annotation only as directed by the DPF runbook. The script never reboots or deletes a host or DPU.
- **NICo secure discovery:** if the DPU agent reports `no machine_interface found for client IP address, and no machine_interface_id was provided`, NICo must map the request to the correct inventory interface or provide a supported explicit interface-ID configuration. A proxy or service-mesh source address may not match a NICo inventory interface. The DPU BMC address is not automatically the request's client address. Do not enable insecure discovery or substitute the BMC IP without NICo guidance.
- **DPU services and chain:** `DPUService` objects being created or pods being Running does not prove DPU readiness. Check the DPU agent registration, FMDS certificate initialization, `DPUServiceInterfaces`, and the generated `DPUServiceChain`. Resolve missing interface/representor expectations with the NICo and DPF owners; do not edit NICo-owned deployment resources by hand as a first response.
- **Readiness:** success requires DPU `Ready=True`, DPU `OperationalReady=True`, and a Ready worker in the HostedCluster. The target returns a failure if these conditions are not met before its timeout.
