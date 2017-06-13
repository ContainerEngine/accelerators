# Nvidia GPU Installer for Container Optimized OS in Container Engine

This is a recipe for installating Nvidia GPU Drivers in Container Engine.

On a Container Engine cluster with GPUs provisioned in one or more node pools, you can run the following command to install Nvidia GPU drivers.

```shell
kubectl create -f https://raw.githubusercontent.com/ContainerEngine/accelerators/master/cos-nvidia-gpu-installer/daemonset.yaml
```

This installer does the following:

1. Disable “loadpin” feature
2. Set the kernel tree to a commit that matches that of the COS kernel version. This is currently managed using an environment variable that needs to be updated for every COS base image.
3. Download Nvidia CUDA Driver Installer Runfile
4. Compile Nvidia drivers against the kernel sources.
5. Load nvidia kernel modules
6. Copy user space libraries and debug tools to a configurable specified directory (`/home/kubernetes/bin/nvidia` by default)
7. Validate installation of drivers
8. Sleep forever (DaemonSets do not support run to completion)

Once the installation is completed, Container Engine nodes provisioned with Nvidia GPUs will expose non zero `Capacity` and `Allocatable` for `alpha.kubernetes.io/nvidia-gpu` resource.

Run `kubectl describe nodes` to view resource `Capacity` for Container Engine nodes.

Consuming Nvidia GPUs from containers isn’t standardized across the Containers ecosystem yet.
Until a standardized solution is available, the solution provided by Container Engine for consuming Nvidia GPUs may not be portable to other Kubernetes deployments.

The installer makes Nvidia user space libraries and debug utilities available under a special directory on the host - `/home/kubernetes/bin/nvidia/`.

A sample Pod Spec is presented below to illustrate how libraries and (optionally) debug utilities can be consumed from within Pods.

```yaml
apiVersion: v1
kind: Pod
spec:
  volumes:
  -  name: nvidia-debug-tools # optional
     hostpath:
       path: /home/kubernetes/bin/nvidia/bin
  -  name: nvidia-libraries # required
     hostpath:
       path: /home/kubernetes/bin/nvidia/lib
  containers:
  - name: gpu-container
    resources:
      limits:
        alpha.kubernetes.io/nvidia-gpu: 2
    volumeMounts:
    - name: nvidia-debug-tools
      mountPath: /usr/local/bin/nvidia
    - name: nvidia-libraries
      mountPath: /usr/local/nvidia/lib64 # This path is special; it is expected to be present in `/etc/ld.so.conf` inside the container image.
```
