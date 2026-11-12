# Logo assets

The SVG and PNG use the libtmux library tile-and-cog geometry with Raku blue
`#0000fb`. The two social images provide light and dark backgrounds.

Exports and renderer: [libtmux/assets, pinned Raku revision][assets]
([artwork PR](https://github.com/libtmux/assets/pull/7)). Palette source:
[GitHub Linguist, pinned revision][linguist]. The existing project artwork
ownership remains unchanged; no separate artwork license is asserted here.
Social images use DejaVu Sans. No font binaries or web-app icon kit are part
of this Raku distribution.

Use the pinned upstream artwork renderer when regenerating exports. The SVG
is the editable library asset. Do not add a Node toolchain to the Raku package
solely to resize logos.

[assets]: https://github.com/libtmux/assets/tree/707c0611c4b949fe254a7fbe13f70d8e074a512a/assets/raku/library
[linguist]: https://github.com/github-linguist/linguist/blob/d456527fe93355baa28c3c29d542c97282b61bc7/lib/linguist/languages.yml
