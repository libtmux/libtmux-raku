use v6.d;

unit module LibTmux::Layout;

use JSON::Fast;
use LibTmux::Types;
use LibTmux::Exceptions;

sub bad(Str:D $message, Int:D :$offset = 0 --> Nil) {
    X::LibTmux::Decode.new(:$message, :schema<layout>, :field<layout>, :$offset).throw
}

#| An immutable observed layout cell; floating leaves need not tile their parent.
class LayoutNode is export {
    #| Pane leaf or horizontal/vertical container kind in the decoded layout.
    has Str:D $.kind is required;
    #| Cell width in terminal columns.
    has Positive:D $.width is required;
    #| Cell height in terminal rows.
    has Positive:D $.height is required;
    #| Horizontal cell offset in terminal columns.
    has Int:D $.x is required;
    #| Vertical cell offset in terminal rows.
    has Int:D $.y is required;
    #| Leaf pane identity; undefined for a container.
    has PaneId $.pane-id;
    #| Optional pane index carried by the modern layout representation.
    has Int $.index;
    #| Optional active-pane flag from the modern layout representation.
    has Bool $.active;
    #| Optional index in the previously visited panes list.
    has Int $.last;
    #| Optional floating-pane stacking index; undefined for tiled cells.
    has Int $.z;
    #| Captured child cells in source order, including floating placements.
    has List:D $.children = ().List;

    submethod TWEAK() { $!children = $!children.map({ $_<> }).eager.List }

    #| Refuse direct cell construction; obtain validated cells through decode-layout.
    method new(| --> Nil) { bad('Obtain captured layout cells through decode-layout') }

    #| Retain parsed cell invariants when using native no-argument cloning.
    method clone(*%changes --> LayoutNode:D) {
        bad('Decode a new layout to change a captured cell') if %changes;
        self.Mu::clone
    }

    #| The JSON dialect carries floating placement through an explicit z-index.
    method floating(--> Bool:D) { $!z.defined }

    #| All leaf cells, retaining source order including floating leaves.
    method panes(--> List:D) {
        $!kind eq 'pane' ?? (self,).List !! $!children.map(*.panes).flat.List
    }
}

#| Decoded layout plus exact source bytes, including unsupported future versions.
class Layout is export {
    #| Exact layout bytes, retained even when the representation is unsupported.
    has Blob:D $.raw is required;
    #| Decoder profile selected by the capability observation.
    has Str:D $.profile is required;
    #| Whether this representation was decoded into the typed node graph.
    has Bool:D $.known = False;
    #| Layout representation version when supplied by the modern dialect.
    has Int $.version;
    #| Decoded root cell; undefined when the layout representation is unknown.
    has LayoutNode $.root;
    #| Captured modal-pane identity when the acquisition context supplies it.
    has Str $.modal-pane-id;
    #| Availability of modal-pane information, distinct from known absence.
    has ValueState:D $.modal-state = Unloaded;

    submethod TWEAK() { $!raw = Blob.new($!raw.list) }

    #| Refuse direct construction; decode source bytes through decode-layout.
    method new(| --> Nil) { bad('Obtain captured layouts through decode-layout') }

    #| Retain agreement between captured bytes, version, and decoded structure.
    method clone(*%changes --> Layout:D) {
        bad('Decode a new layout to change captured data') if %changes;
        self.Mu::clone
    }

    method !require(--> Nil) {
        X::LibTmux::MissingData.new(:field<layout>, :state(Unsupported),
            :message('Layout dialect or version has not been decoded')).throw unless $!known;
        Nil
    }

    #| Leaf cells which participate in tiling; this is not the complete pane set.
    method tiled(--> List:D) {
        self!require;
        $!root.defined ?? $!root.panes.grep({ !.floating }).List !! ().List
    }

    #| Floating placements retain their signed offsets and observed stacking order.
    method floating(--> List:D) {
        self!require;
        $!root.defined ?? $!root.panes.grep(*.floating).List !! ().List
    }

    #| Resolve separately acquired modal identity; the layout string does not encode it.
    method modal() {
        self!require;
        X::LibTmux::MissingData.new(:field<modal-pane-id>, :state(Unloaded),
            :message('Modal identity was not acquired')).throw if $!modal-state == Unloaded;
        return Nil if $!modal-state == KnownNull;
        my $pane = $!root.defined ?? $!root.panes.first(*.pane-id eq $!modal-pane-id) !! Nil;
        X::LibTmux::MissingData.new(:field<modal-pane-id>, :state(Unavailable),
            :message('Modal pane is not represented in this layout')).throw unless $pane.defined;
        $pane
    }
}

grammar Classic {
    token TOP { <node> }
    token uint { <[0..9]>+ }
    token int { '-'? <[0..9]>+ }
    token node {
        <width=uint> 'x' <height=uint> ',' <x=int> ',' <y=int>
        [ ',' <pane=uint> | <horizontal> | <vertical> ]
    }
    token horizontal { '{' <node>+ % ',' '}' }
    token vertical { '[' <node>+ % ',' ']' }
}

class ClassicActions {
    has Int:D $.max-nodes is required;
    has Int $!count = 0;

    method horizontal($/) { make $<node>.map(*.made).List }
    method vertical($/) { make $<node>.map(*.made).List }
    method node($/) {
        bad('Layout node count exceeds limit') if ++$!count > $!max-nodes;
        my $width = +$<width>;
        my $height = +$<height>;
        bad('Layout dimensions must be positive') unless $width > 0 && $height > 0;
        my @children;
        my $kind = 'pane';
        if $<horizontal> {
            @children = $<horizontal>.made.List;
            $kind = 'horizontal';
        } elsif $<vertical> {
            @children = $<vertical>.made.List;
            $kind = 'vertical';
        }
        bad('Split layout requires at least two children')
            if $kind ne 'pane' && @children.elems < 2;
        make LayoutNode.bless(:$kind, :$width, :$height, :x(+$<x>), :y(+$<y>),
            :pane-id($<pane> ?? '%' ~ ~$<pane> !! PaneId),
            :children(@children.map({ $_<> }).List));
    }
    method TOP($/) { make $<node>.made }
}

# The emitted subset has integer numbers, nonempty strings, and arrays of objects.
grammar JsonSubset {
    rule TOP { <object> }
    rule object { '{' [ <member>+ % ',' ]? '}' }
    rule member { <key=string> ':' <value> }
    rule array { '[' [ <object>+ % ',' ]? ']' }
    rule value { <object> | <array> | <string> | <integer> | 'true' | 'false' }
    token integer { '-'? [ '0' | <[1..9]> <[0..9]>* ] }
    token string {
        '"' [
            <-["\\\x00..\x1f]>
            | '\\' <["\\/bfnrt]>
            | '\\u' <[0..9a..fA..F]> ** 4
        ]+ '"'
    }
}

class JsonChecks {
    method object($/) {
        my %seen;
        for $<member>.List -> $member {
            my $key = from-json(~$member<key>);
            bad('Duplicate JSON layout key',
                :offset($/.orig.substr(0, $member<key>.from).encode('utf8').elems))
                if %seen{$key}++;
        }
    }
    method integer($/) {
        my $value = (~$/).Int;
        bad('JSON layout integer exceeds signed 64-bit range')
            unless -(2 ** 63) <= $value < 2 ** 63;
    }
}

sub bounded-text(Blob:D $bytes, Positive:D $max-depth --> Str:D) {
    my $text;
    try {
        $text = $bytes.decode('utf8');
        CATCH { default { bad('Layout is not valid UTF-8') } }
    }
    my Int $depth = 0;
    my Bool $quoted = False;
    my Bool $escaped = False;
    my Int $digits = 0;
    for $bytes.list.kv -> $offset, $byte {
        bad('NUL in layout', :$offset) if $byte == 0;
        if $quoted {
            if $escaped { $escaped = False }
            elsif $byte == 92 { $escaped = True }
            elsif $byte == 34 { $quoted = False }
            next;
        }
        $quoted = True if $byte == 34;
        $depth++ if $byte == any(123, 91);
        $depth-- if $byte == any(125, 93);
        bad('Layout nesting exceeds limit', :$offset) if $depth > $max-depth;
        $digits = 48 <= $byte <= 57 ?? $digits + 1 !! 0;
        bad('Layout number exceeds lexical limit', :$offset) if $digits > 20;
    }
    $text
}

sub integer($value, Str:D $field, Bool :$unsigned = False --> Int:D) {
    bad("Layout $field requires an integer") unless $value ~~ Int:D && $value !~~ Bool;
    bad("Layout $field must be nonnegative") if $unsigned && $value < 0;
    $value.Int
}

sub json-node($data, Int:D $maximum, Int:D $count is rw --> LayoutNode:D) {
    bad('Layout node count exceeds limit') if ++$count > $maximum;
    bad('Layout cell must be an object') unless $data ~~ Hash:D;
    my $kind = $data<t>;
    bad('Unknown layout cell type') unless $kind ~~ Str:D && $kind eq any(<h v p>);
    my %allowed = <t w h x y>.map({ $_ => True });
    %allowed{$_} = True for ($kind eq 'p' ?? <I i a l z> !! <c>);
    bad('Unexpected layout cell field') if $data.keys.first({ !(%allowed{$_}:exists) }).defined;
    my $width = integer($data<w>, 'width', :unsigned);
    my $height = integer($data<h>, 'height', :unsigned);
    bad('Layout dimensions must be positive') unless $width > 0 && $height > 0;
    my $x = integer($data<x>, 'x');
    my $y = integer($data<y>, 'y');
    my @children;
    my %leaf;
    if $kind eq 'p' {
        bad('Invalid layout pane ID') unless $data<I> ~~ PaneId:D;
        %leaf<pane-id> = $data<I>.Str;
        %leaf<index> = integer($data<i>, 'index', :unsigned);
        %leaf<active> = False;
        for <l z> -> $field {
            %leaf{$field eq 'l' ?? 'last' !! 'z'} = integer($data{$field}, $field, :unsigned)
                if $data{$field}:exists;
        }
        if $data<a>:exists {
            bad('Layout active flag must be Boolean') unless $data<a> ~~ Bool:D;
            %leaf<active> = $data<a>;
        }
        bad('Active pane cannot have last-visited rank') if ($data<a>:exists) && ($data<l>:exists);
    } else {
        bad('Split layout requires at least two children')
            unless $data<c> ~~ Array:D && $data<c>.elems >= 2;
        @children = $data<c>.map({ json-node($_, $maximum, $count) });
    }
    LayoutNode.bless(:kind({ h => 'horizontal', v => 'vertical', p => 'pane' }{$kind}),
        :$width, :$height, :$x, :$y, |%leaf,
        :children(@children.map({ $_<> }).List))
}

sub validate-leaves(LayoutNode:D $root, Bool :$json = False --> Nil) {
    my %ids; my %indexes; my %z; my %last;
    my Int $active = 0;
    for $root.panes -> $pane {
        bad('Repeated pane ID in layout') if %ids{$pane.pane-id}++;
        if $json {
            bad('Repeated pane index in layout') if %indexes{$pane.index}++;
            bad('Repeated floating z-index') if $pane.z.defined && %z{$pane.z}++;
            bad('Repeated last-visited rank') if $pane.last.defined && %last{$pane.last}++;
            $active++ if $pane.active.defined && $pane.active;
        }
    }
    bad('More than one active pane in layout') if $active > 1;
    Nil
}

#| Decode a declared dialect. Unknown versions retain bytes without a guessed tree.
multi sub decode-layout(Str:D $raw, *%options --> Layout:D) is export {
    decode-layout($raw.encode('utf8'), |%options)
}

multi sub decode-layout(Blob:D $raw, Str:D :$profile!,
                        Str :$modal-pane-id,
                        Positive:D :$max-bytes = 1024 * 1024,
                        Positive:D :$max-depth = 64,
                        Positive:D :$max-nodes = 10000 --> Layout:D) is export {
    bad('Layout exceeds byte limit') if $raw.elems > $max-bytes;
    my $bytes = Blob.new($raw.list);
    my %modal;
    if $modal-pane-id.defined {
        bad('Invalid modal pane ID') if $modal-pane-id.chars && $modal-pane-id !~~ PaneId;
        %modal<modal-state> = $modal-pane-id.chars ?? Present !! KnownNull;
        %modal<modal-pane-id> = $modal-pane-id if $modal-pane-id.chars;
    }
    return Layout.bless(:raw($bytes), :$profile, |%modal)
        unless $profile eq any(<classic json>);
    my $text = bounded-text($bytes, $max-depth);
    my LayoutNode $root;
    my Int $version;
    if $profile eq 'classic' {
        bad('Malformed classic layout header')
            unless $text ~~ /^ <[0..9a..fA..F]> ** 4 ',' /;
        my $body = $text.substr(5);
        my Int $checksum = 0;
        for $body.encode('utf8').list -> $byte {
            $checksum = (($checksum +> 1) + (($checksum +& 1) +< 15) + $byte) +& 65535;
        }
        bad('Classic layout checksum mismatch') unless $checksum == $text.substr(0, 4).parse-base(16);
        if $body.chars {
            my $parsed = Classic.parse($body, :actions(ClassicActions.new(:$max-nodes)));
            bad('Malformed classic layout tree') unless $parsed;
            $root = $parsed.made;
        }
        $version = 1;
    } else {
        my $data;
        try {
            $data = from-json($text);
            CATCH { default { bad('Malformed JSON layout') } }
        }
        bad('Layout JSON requires a top-level object') unless $data ~~ Hash:D;
        $version = integer($data<V>, 'version', :unsigned);
        return Layout.bless(:raw($bytes), :$profile, :$version, |%modal) unless $version == 2;
        bad('JSON layout violates the emitted subset')
            unless JsonSubset.parse($text, :actions(JsonChecks.new));
        bad('Unexpected JSON layout header field') unless $data.keys.sort.List eqv <L V>.List;
        my Int $count = 0;
        $root = json-node($data<L>, $max-nodes, $count);
    }
    validate-leaves($root, :json($profile eq 'json')) if $root.defined;
    Layout.bless(:raw($bytes), :$profile, :known, :$version, :$root, |%modal)
}

=begin pod
=head1 Observed layouts
Construct layouts and their cells through C<decode-layout>; direct C<new>
calls are refused so captured bytes and validated structure stay together.

Classic layouts validate their checksum and represented tiled tree; C<0000,>
is the compatibility sentinel for no represented tiled cells. It does not
prove the physical window lacks floating panes. JSON version 2 retains
all cells, including floating placements with signed coordinates and z-index.
The separate C<window_modal_pane> observation supplies C<:modal-pane-id>; an
empty string means known absence, while omission means not acquired.

Unknown dialects and versions expose exact immutable C<raw> bytes and
C<known == False>. They do not fabricate a tiled interpretation. Parsing and
traversal perform no I/O. Input bytes, nesting, numeric spelling and node
counts are bounded before or during parsing.
=end pod
