<p align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="LibTmux Raku logo">
  </picture>
</p>

# LibTmux for Raku

A Raku library for tmux snapshots, queries and explicit commands, currently
in development. The package foundation provides typed identifiers and errors;
the server, graph, command and control APIs are being implemented.

The intended runtime is Linux, stable Raku 6.d on the current Rakudo/MoarVM,
and tmux from the supported floor through the current endpoint. Compatibility
is established by the required tests, not by this development description.

See [contributing](.github/CONTRIBUTING.md) for setup and verification, and
[writing](.github/WRITING.md) for documentation conventions. Logo assets
and source provenance live in [docs/assets](docs/assets/README.md).
The repository remains private; no package has been published.
