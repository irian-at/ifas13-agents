# CLAUDE.local.md

## Application 
 
- The new IFAS13 application is based on a legacy CPP application. The sources for this legacy application are
  located at ~/dev/projects/oekb/ifas

## Platform
 
- NixOS/Linux, AMD64, fish shell
- nixos config is located at ~/nixos-config
- IntelliJ IDEA with JetBrains MCP plugin

## Required Maven Profiles

Always activate `-Pno-proxy` (no proxy needed on this network):

```bash
mvn clean install -Pno-proxy
```

Note: `-Pplatform-amd64` is active by default in the project POMs, so it does not need to be specified explicitly (Manfred uses `-Pplatform-arm64` because his Apple Silicon platform requires overriding the default).
