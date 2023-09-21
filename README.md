# Toolchain Install

A script and some manifests to install [codeready-toolchain's operators](https://github.com/codeready-toolchain) with in-cluster Keycloak based authentication on a [CRC cluster](https://github.com/crc-org/crc).

The script `install.sh` performs the following actions:
* Creates a big enough cluster with monitoring enabled (Toolchain's requirement)
* Installs Keycloak (via RHSSO Operator) and configures a realm for authentication
* Configures login into the cluster via Keycloak (cf. `oauths.config.openshift.io`)
* Installs the latest version of Toolchain (Host and Member operators, and registration-service)
* Patches the Toolchain's `registration-service` to use the internal Keycloak
* Restarts the `registration-service` to ensure patched configuration is used


## Keycloak enabled cluster CRC Bundle

To speed up the creation of the Keycloak enabled cluster, the following approach can be used.
Find this code in the `install.sh`, and remove the `#` before the `exit 0`
```
### Uncomment this if following the procedure to create
### a Keycloak enabled cluster CRC Bundle
# exit 0
```

Execute the script and when it completes execute the following command:
```
crc bundle generate
```

CRC will stop the cluster and produce an image that you can execute using
```
crc start -b <PATH_TO_BUNDLE>.crcbundle
```
