![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg)

# `tt_um_adpll_dco` — a DCO test chip for Tiny Tapeout TTSKY26d

A digitally controlled ring oscillator on a 1×2 tile, commanded by fifteen
static code pins and instrumented to measure itself: two divider chains and an
on-chip frequency counter. SkyWater 130 nm.

- [Datasheet page](docs/info.md)

This repository publishes a pre-hardened layout: `gds/tt_um_adpll_dco.gds` is
not rebuilt by the GitHub Action. The `gds` workflow checks it against
`signoff/SHA256SUMS` and publishes it unchanged through Tiny Tapeout's
`custom_gds` action. `src/` is the RTL it was built from.

## Licence

Apache-2.0, see [LICENSE](LICENSE).
