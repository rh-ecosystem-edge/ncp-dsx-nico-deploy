# NICo fork and midstream flow

NVIDIA's [infra-controller](https://github.com/dsx-ai-factory/infra-controller) is the upstream source. Red Hat's [infra-controller fork](https://github.com/rh-ecosystem-edge/infra-controller) collects OpenShift changes on `next` before the [DSX midstream](https://github.com/rh-ecosystem-edge/dsx-ai-factory) pins a tested commit as a submodule. This deployment repository also pins that fork under `helm/vendor/infra-controller`.

1. Open focused source PRs against NVIDIA upstream for fixes NVIDIA should own. Keep each PR to one reviewed commit. Do not push directly to upstream branches.
2. Integrate those PRs in a fork PR targeting `next`. Resolve interactions there and run source tests plus the deployment chart checks. Keep a link to every source PR in the integration PR.
3. Pin the tested fork commit by SHA in this repository and in the midstream `next-nico` branch. A submodule branch setting is only a tracking hint; the gitlink SHA is what deployments actually use. Review the pin in PRs before merging.
4. Once NVIDIA releases a GA version containing the source fixes, update the fork's stable line, retest, and promote the tested submodule SHA to the midstream main branch.

Current integration: [fork PR #1](https://github.com/rh-ecosystem-edge/infra-controller/pull/1) combines NVIDIA source PRs #4372, #8796, #8183, #8609, and #8798. The NCP integration combines [#29](https://github.com/rh-ecosystem-edge/ncp-dsx-nico-deploy/pull/29), [#30](https://github.com/rh-ecosystem-edge/ncp-dsx-nico-deploy/pull/30), [#31](https://github.com/rh-ecosystem-edge/ncp-dsx-nico-deploy/pull/31), [#32](https://github.com/rh-ecosystem-edge/ncp-dsx-nico-deploy/pull/32), and [#33](https://github.com/rh-ecosystem-edge/ncp-dsx-nico-deploy/pull/33). These branches remain open for their own reviews. Pin the final `next` merge commit after fork PR #1 merges.

For each pin, run `make helm-lint`, `make helm-template`, and the site-specific DPF/NICo render checks. A successful render does not prove hardware onboarding. Record the exact image/chart builds and a separate lab result before promoting to the stable line.
