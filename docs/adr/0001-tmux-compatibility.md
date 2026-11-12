# tmux compatibility

Status: accepted.

## Decision

Support Linux and the declared stable tmux releases from 3.3a through 3.8.
Use the daemon's version and observed capabilities when selecting commands,
fields, codecs and layouts. A newer client executable does not upgrade the
daemon. Unknown and vendor releases require an explicit support decision.

Keep release profiles in [LibTmux::Catalogue](../../lib/LibTmux/Catalogue.rakumod).
Each profile names its upstream commit. The oldest and newest profiles define
the required live CI jobs; intermediate releases retain pure compatibility
fixtures. Feature boundaries and known defects belong in the field catalogue.

## Rationale

Runtime checks and CI must agree on supported releases. Typed release records
provide one source for both without a separate configuration format. CI verifies
the fetched tag against the pinned commit; it does not need a second inventory
of individual source-file hashes.

Adding a supported release requires reviewing its feature and defect policies,
updating its profile, and passing the relevant fixtures and endpoint tests.
