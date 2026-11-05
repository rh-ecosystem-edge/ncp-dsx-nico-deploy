# OpenShift DPF Zero Trust with NICo

This repository deploys NICo. The OpenShift DPF automation owns the DPF platform and HostedCluster lifecycle. NICo owns the DPU inventory and the DPF resources generated from its site configuration; DPF controllers provision the DPU and reconcile those resources. Do not run the standalone DPF workload-manifest path when NICo owns the deployment.

## Deployment sequence

Use the NICo integration in [openshift-dpf PR #510](https://github.com/rh-ecosystem-edge/openshift-dpf/pull/510). It preserves the standalone DPF flow by default and adds an explicit NICo handoff:

1. In the DPF automation's protected `.env`, set `DPF_DEPLOYMENT_MODE=zero-trust`, `NICO_ENABLED=true`, and `NICO_DPU_DEPLOYMENT_NAME` to the deployment name used by the NICo site configuration.
2. Run the DPF platform stage (`make all-zt`). In NICo mode it installs DPF and the HostedCluster prerequisites, then stops before creating the HostedCluster.
3. Deploy NICo with this repository's existing `make deploy-all-site` target and the appropriate per-site values. The NICo site configuration must keep `[dpf].enabled = true` and define the matching DPU deployment, BFB, services, and images.
4. After NICo creates the configured `DPUDeployment`, continue with `make deploy-hosted-cluster` in the DPF automation. Once the HostedCluster API is ready, run `make deploy-zt-dpu-services` to apply the hosted-cluster DPF authorization.
5. DPF controllers provision the DPU and reconcile NICo's DPU services. Verify the DPU and HostedCluster worker conditions before treating onboarding as complete.

The exact DPF targets and required settings are owned by the [DPF automation](https://github.com/rh-ecosystem-edge/openshift-dpf/pull/510). Keep `DPF_DEPLOYMENT_MODE`, `NICO_ENABLED`, and `NICO_DPU_DEPLOYMENT_NAME` in that repo's environment; they are not NCP Helm values or `deploy.env` settings.

## NICo site configuration

Use the existing NCP targets rather than a wrapper that calls a second repository's Makefile. Put deployment-specific NICo DPF settings in the per-site Core site configuration (`helm/values/nico-core-<SITE>.yaml`), including the same DPU deployment name supplied to DPF. Keep credentials in the DPF automation's protected environment or a cluster Secret; do not commit BMC passwords, pull secrets, or kubeconfigs. The checked-in `deploy.env.example` is for safe NCP site-selection values, not secrets or DPF orchestration.

Set chart-specific exceptions in that site's `[dpf.services.<service>.extra_helm_values]` configuration, not in global chart defaults. For example, on the tested RHCOS DPU image the LLDP sidecar needs `lldpSidecar.hostLibraryPath = "/usr/lib64"`; the generic chart default remains empty. This requires the optional chart support in [infra-controller PR #8798](https://github.com/dsx-ai-factory/infra-controller/pull/8798). Publish and pin the chart through the site's approved chart repository. The NCP deployment flow should not package a local chart into a lab ConfigMap or patch NICo-generated `DPUServiceConfiguration` objects.

`NICO_DPF_EXTERNAL=true` is for the upstream `infra-controller/helm-prereqs/setup.sh` installer path. NCP deploys NICo through its own Helm targets and does not invoke that script, so do not add that variable to NCP's `deploy.env` for this flow. If an installation uses the upstream setup script instead, follow its external-DPF instructions and the companion [infra-controller PR #8183](https://github.com/dsx-ai-factory/infra-controller/pull/8183).

## Manual prerequisites and validation

Before deployment, provide the DPF automation with the site-specific pull secrets, BFB endpoint, and DPU/host BMC inventory required by its Zero Trust profile. NICo also needs valid BMC credentials and inventory that lets secure discovery map the agent request to the correct machine interface. A BMC address is not a substitute for the source interface used by the discovery request.

The NICo/DPF handoff is not a complete end-to-end test by itself. Validate that the DPU agent registers, FMDS certificates are issued, DPU service interfaces and the service chain become ready, the DPU reaches `Ready=True` and `OperationalReady=True`, and the worker is Ready in the HostedCluster. If NICo receives a proxy or egress address that has no matching machine interface, resolve that source-address mapping with the NICo networking/inventory owner; do not disable secure discovery or patch generated DPF resources as a workaround.
