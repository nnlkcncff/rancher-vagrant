This project was designed to bring order to all Rancher-related Kubernetes clusters (remove any configuration drift, configuration mistakes and flaws, to upgrade all deployed applications and operation systems, etc).

<br>

# App Rancher testing environment

## Overview

![](Vagrant%20App%20Rancher.drawio.svg)

The project was created in order to test any changes before implementing them on [App Rancher](https://rancher.app.test). It replicates almost everything, but there are also some differencies mostly to provide some flexibility for different cases. The most important differencies are:
  - cluster nodes CIDR is different (in order to allow and simplify connectivity with real clusters if needed)
  - high availability (HA) is implemented for each cluster (MetalLB is used for HA as a proof-of-concept in case it is not possible to agree on external load balancing)
  - MetalLB bundle is deployed by RKE2 (due to HA it's needed before Fleet can deploy it)
  - Rancher deployment has 3 replicas
  - container registry mirroring is disabled to significantly reduce deployment time (to enable it uncomment variable `CONTAINER_REGISTRY_MIRROR` in `Vagrantfile`)
  - etcd backup to NFS is enabled for all clusters inlcuding `local` (only the `app-*` clusters are backed up in production)
  - no external authentication

![](RKE2%20fixed%20registration%20MetalLB%20address.drawio.svg)

It's not completed to the intended state mainly due to the plan to move to the private cloud where things would be completely different, but also due to some limitations imposed on App Rancher.

## Setup

Requirements:
  - git remote access
  - software:
    - [x86_64 CPU architecture](https://en.wikipedia.org/wiki/X86-64)
    - [HashiCorp Vagrant](https://developer.hashicorp.com/vagrant/install)
    - [Oracle VirtualBox](https://developer.hashicorp.com/vagrant/docs/providers/virtualbox)
  - variables in `secrets-prod.rb` (the values can be obtained from the production environment, for the syntax see `secrets-prod.rb.example`)
    - `CONTAINER_REGISTRY`, `CONTAINER_REGISTRY_USER`, `CONTAINER_REGISTRY_PASSWORD`
    - `TLS_RANCHER_INGRESS_KEY`, `TLS_RANCHER_INGRESS_CRT`
    - `SEALED_SECRETS_KEY`, `SEALED_SECRETS_CRT`
  - variable `FLEET_ROOT_SEALED_SECRET` in `repo.rb` (uncomment it)

> Limited functionality with GitRepos deployed, but without the ability to unseal their bundle secrets: no any variables declared in `secrets-prod.rb`, no variable `FLEET_ROOT_SEALED_SECRET` in `repo.rb`.

Deploying the environment:
```shell
git clone https://github.com/nnlkcncff/rancher-vagrant.git --recurse-submodules
cd rancher-vagrant
vagrant up
```

> Reduced resource consumption by running without HA: \
> `vagrant up Infrastructure 'local CP1' '/app-tools.*1/' '/app-build.*1/' '/app-deploy.*1/'`

Login to Rancher: user `admin`, the password is defined by `BOOTSTRAP_PASSWORD` in `secrets-local.rb`.

