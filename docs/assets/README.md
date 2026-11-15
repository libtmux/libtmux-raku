# Logo assets

The SVG and PNG use the libtmux library tile-and-cog geometry with Raku blue
`#0000fb`. The two social images provide light and dark backgrounds and show a native
query selecting the pane titled `editor`.

Exports and renderer: [libtmux/assets, pinned Raku revision][assets]
([artwork PR](https://github.com/libtmux/assets/pull/7)). Palette source:
[GitHub Linguist, pinned revision][linguist]. The social cards use the asset kit's outlined fonts.

The social cards come from [the verified query update][cards]. Their exact
query was exercised on a private tmux server with matching and missing panes.

Use the pinned upstream artwork renderer when regenerating exports. The SVG
is the editable library asset.

[assets]: https://github.com/libtmux/assets/tree/707c0611c4b949fe254a7fbe13f70d8e074a512a/assets/raku/library
[linguist]: https://github.com/github-linguist/linguist/blob/d456527fe93355baa28c3c29d542c97282b61bc7/lib/linguist/languages.yml

[cards]: https://github.com/libtmux/assets/tree/a6377dd4fbfe0d5e59271ceefb21cb503646dbc0/assets/raku/library
