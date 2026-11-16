use v6.d;
use experimental :rakuast;
use JSON::Fast;

# Author tool: parsing trusted source may execute compile-time code.
my constant @ADVANCED = <LibTmux::Format LibTmux::Layout LibTmux::Configuration
    LibTmux::Catalogue LibTmux::Control>;
my constant @VALUES = <LibTmux::Engine::Endpoint LibTmux::Engine::Incarnation
    LibTmux::Engine::Observation>;

sub command(*@args --> Str:D) {
    my $proc = run |@args, :out;
    my $output = $proc.out.slurp(:close);
    die "Documentation command failed: {@args[0]}" if $proc.exitcode;
    $output.chomp
}

sub input-hashes(@files --> Hash:D) {
    command('sha256sum', |@files).lines.map({
        my ($hash, $path) = .split('  ', 2); $path => $hash
    }).Hash
}

sub plain-name($node --> Str:D) { $node.name.DEPARSE }
sub line-of($node --> Int:D) { ($node.fileline.split(':').tail // '1').Int }
sub utf16-length(Str:D $text --> Int:D) { $text.encode('utf16le').elems div 2 }

sub markup($node, :@links = [] --> Str:D) {
    return $node if $node ~~ Str;
    my $kind = $node.^name;
    if $kind eq 'RakuAST::Doc::Markup' {
        return '' if $node.letter eq 'Z';
        my $text = $node.letter eq 'C' ?? $node.atoms.map(&markup).join
            !! $node.atoms.map({ markup($_, :@links) }).join;
        given $node.letter {
            when 'B' { return "**$text**" }
            when 'I' { return "*$text*" }
            when 'C' {
                my $ticks = '`' x (1 + (0, |$text.comb(/ '`'+ /)>>.chars).max);
                # CommonMark pads a span only to keep an edge backtick from fusing with a delimiter.
                my $pad = $text.starts-with('`') || $text.ends-with('`') ?? ' ' !! '';
                return $ticks ~ $pad ~ $text ~ $pad ~ $ticks;
            }
            when 'L' {
                my $target = $node.meta.elems ?? $node.meta.map(&markup).join !! $text;
                die 'Unsupported bracket in RakuDoc link label' if $text.contains('[') || $text.contains(']');
                return "[$text]($target)" if $target.starts-with('https://');
                @links.push($target);
                return "[$text](rakudoc:" ~ $target.encode.list.map({
                    $_ >= 65 && $_ <= 90 || $_ >= 97 && $_ <= 122 || $_ >= 48 && $_ <= 57
                        || $_ == any(45, 46, 95, 126) ?? .chr !! '%' ~ .fmt('%02X')
                }).join ~ ')';
            }
            when 'E' {
                die 'Unresolved RakuDoc entity' unless $node.meta.elems
                    && $node.meta.all ~~ Pair;
                return $node.meta.map(*.value).join;
            }
            default { return $text }
        }
    }
    return $node.atoms.map({ markup($_, :@links) }).join if $kind eq 'RakuAST::Doc::Paragraph';
    if $kind eq 'RakuAST::Doc::Block' {
        return '' if $node.type eq 'comment';
        my $code = $node.type eq any(<code implicit-code>);
        my $text = $code ?? $node.paragraphs.map(&markup).join
            !! $node.paragraphs.map({ markup($_, :@links) }).join;
        given $node.type {
            when 'head' { return "\n\n" ~ '#' x $node.level ~ ' ' ~ $text.trim ~ "\n\n" }
            # An indented paragraph is an implicit code block; Rakudo has already
            # removed its common indent, so relative indentation is what remains.
            when 'code' | 'implicit-code' {
                my $lang = $node.podify.config<lang> // 'raku';
                return "\n\n```$lang\n" ~ $text.subst(/ \n+ $/, '') ~ "\n```\n\n";
            }
            # Indent wrapped lines: the site's list reader ends an item at a line in column zero.
            when 'item' { return "\n\n- " ~ $text.trim.subst("\n", "\n  ", :g) ~ "\n\n" }
            when 'NAME' { return "\n\n# " ~ $text.trim ~ "\n\n" }
            default { return $text }
        }
    }
    die "Unsupported native documentation node $kind";
}

sub documentation($node --> Hash:D) {
    return %() unless $node.^can('WHY') && $node.WHY.defined;
    my @links;
    my $body = $node.WHY.paragraphs.map({ markup($_, :@links) }).join.trim;
    $body.chars ?? %(summary => $body.split("\n\n")[0], body => $body,
        _nativeLinks => @links.Array) !! %()
}

sub resolve-link(Str:D $target, %owner, %symbols, %aliases --> Str:D) {
    return $target if %symbols{$target}:exists;
    return %aliases{$target} if %aliases{$target}:exists
        && (%symbols{%aliases{$target}}:exists);
    my $scoped = (%owner<parent> // %owner<id>) ~ '::' ~ $target;
    return $scoped if %symbols{$scoped}:exists;
    return %aliases{$scoped} if %aliases{$scoped}:exists
        && (%symbols{%aliases{$scoped}}:exists);
    my @matching = %symbols.values.grep({ .<name> eq $target });
    die "Unresolved or ambiguous RakuDoc target '$target' in {%owner<id>}"
        ~ " ({%owner<source><file>}:{%owner<source><line>})"
        unless @matching.elems == 1;
    @matching[0]<id>
}

sub validate-links(@symbols, %aliases --> Nil) {
    my %by-id = @symbols.map({ .<id> => $_ }).Hash;
    for @symbols -> %owner {
        my @docs = %owner<doc>, |(%owner<signatures> // []).map(*.<doc>);
        for @docs.grep({ .defined && .elems }) -> %doc {
            die "Native link metadata missing for {%owner<id>}; extract source before validation"
                unless %doc<_nativeLinks>:exists;
            resolve-link($_, %owner, %by-id, %aliases) for %doc<_nativeLinks>.List;
        }
    }
}

sub signature($node --> Hash:D) {
    my $signature = $node.signature;
    my $inside = $signature.defined ?? ($signature.SOURCE // $signature.DEPARSE) !! '';
    my $name = plain-name($node);
    my $prefix = ($node.^name eq 'RakuAST::Method' ?? 'method ' !! 'sub ') ~ $name ~ '(';
    my $raw = $prefix ~ $inside ~ ')';
    my @params;
    if $signature.defined {
        for $signature.parameters -> $parameter {
            next if $parameter.invocant || !$parameter.origin.defined;
            my %param = name => ($parameter.target.defined ?? $parameter.target.DEPARSE !! $parameter.SOURCE),
                optional => so $parameter.is-optional,
                keywordOnly => so $parameter.named;
            %param<type> = $parameter.type.DEPARSE if $parameter.type.defined && $parameter.type.DEPARSE.chars;
            %param<default> = $parameter.default.SOURCE // $parameter.default.DEPARSE
                if $parameter.default.defined;
            %param<variadic> = %param<name>.starts-with('%') ?? 'keyword' !! 'positional'
                if $parameter.slurpy;
            @params.push(%param);
        }
    }
    my @references;
    my %seen;
    if $signature.defined && $signature.origin.defined {
        for $signature.grep({ .^name eq 'RakuAST::Type::Simple' && .origin.defined }) -> $type {
            next unless $type.has-compile-time-value;
            my $target = $type.compile-time-value.^name;
            next unless $target.starts-with('LibTmux::') || $target.starts-with('X::LibTmux')
                || $type.compile-time-value.HOW.^name.contains('EnumHOW');
            my $offset = $type.origin.from - $signature.origin.from;
            next if $offset < 0 || $offset >= $inside.chars;
            my $start = utf16-length($prefix ~ $inside.substr(0, $offset));
            my $end = $start + utf16-length($type.SOURCE);
            next if %seen{"$start:$end:$target"}++;
            @references.push(%(:$start, :$end, :$target));
        }
    }
    my %result = :$raw, params => @params, references => @references;
    %result<returns> = $signature.returns.DEPARSE
        if $signature.defined && $signature.returns.defined;
    %result
}

sub extract-unit(Str:D $file --> Hash:D) {
    my $tree = $file.IO.slurp.AST;
    my @declarations;
    my @guides;
    my @guide-links;
    my %seen;
    sub walk($node, Str:D $owner = '') {
        return if %seen{$node.WHICH}++;
        my $kind = $node.^name;
        return if $kind eq 'RakuAST::Doc::Declarator';
        if $kind eq 'RakuAST::Doc::Block' {
            @guides.push(markup($node, :links(@guide-links))) if $node.type eq any(<pod NAME DESCRIPTION>);
            return;
        }
        my $next-owner = $owner;
        my %symbol;
        if $kind eq any(<RakuAST::Class RakuAST::Role RakuAST::Module RakuAST::Type::Subset RakuAST::Type::Enum>) {
            return if $node.^can('is-stub') && $node.is-stub;
            my $name = plain-name($node);
            my $id = $node.meta-object.^name;
            $id = $owner ~ '::' ~ $name if $kind eq 'RakuAST::Type::Enum' && !$id.contains('::');
            $next-owner = $id;
            %symbol = :$id, :$name, kind => ({
                'RakuAST::Class' => 'class', 'RakuAST::Role' => 'trait',
                'RakuAST::Module' => 'module', 'RakuAST::Type::Subset' => 'typealias',
                'RakuAST::Type::Enum' => 'enum',
            }{$kind});
            %symbol<kind> = 'exception' if $kind eq 'RakuAST::Class'
                && $node.meta-object.^isa(Exception);
            %symbol<name> = $name.substr(8) if $name.starts-with('GLOBAL::');
            if $kind eq 'RakuAST::Class' {
                my @parents = $node.meta-object.^parents.map(*.^name)
                    .grep({ .starts-with('LibTmux') || .starts-with('X::LibTmux') || $_ eq 'Exception' });
                %symbol<extends> = @parents if @parents;
            }
            %symbol<parent> = $owner if $owner.chars;
            %symbol<signatures> = [];
        } elsif $kind eq any(<RakuAST::Method RakuAST::Sub>) {
            return if $node.^can('private') && $node.private;
            my $name = plain-name($node);
            return unless $name.chars;
            %symbol = id => $owner ~ '.' ~ $name, :$name, :parent($owner),
                kind => ($kind eq 'RakuAST::Method' ?? 'method' !! 'function'),
                signatures => [signature($node).item];
        } elsif $kind eq 'RakuAST::VarDeclaration::Simple' && $node.scope eq 'has' && $node.twigil eq '.' {
            my $name = $node.desigilname.DEPARSE;
            %symbol = id => "$owner.$name", :$name, :parent($owner), kind => 'property',
                signatures => [];
            %symbol<type> = $node.type.DEPARSE if $node.type.defined;
        }
        if %symbol && $node.origin.defined {
            %symbol<source> = %(file => $file, line => line-of($node));
            %symbol<doc> = documentation($node);
            %symbol<modifiers> = [];
            @declarations.push(%symbol);
            if $kind eq 'RakuAST::Type::Enum' {
                for $node.meta-object.enums.sort(*.value) -> $case {
                    @declarations.push(%(id => %symbol<id> ~ '.' ~ $case.key,
                        parent => %symbol<id>, name => $case.key, kind => 'constant',
                        modifiers => [], signatures => [], value => $case.value.Str,
                        source => %symbol<source>, doc => %symbol<doc>));
                }
            }
        }
        return if $kind eq any(<RakuAST::Method RakuAST::Sub RakuAST::VarDeclaration::Simple>);
        $node.visit-children(-> $child { walk($child, $next-owner) });
    }
    walk($tree);
    %(declarations => @declarations, guide => @guides.join("\n\n").trim,
        guideLinks => @guide-links.Array)
}

sub runtime-surface(--> Hash:D) {
    require LibTmux;
    my %types;
    my %aliases;
    my @functions;
    for 'LibTmux', |@ADVANCED -> $name {
        require ::($name);
        my $module = ::($name);
        %types{$name} = $module;
        for $module.WHO<EXPORT>.WHO<DEFAULT>.WHO.kv -> $export, $value {
            if $value ~~ Code {
                @functions.push(%(module => $name, name => $export.substr(1),
                    file => $value.file, line => $value.line));
            } elsif !$value.DEFINITE {
                my $native = $value.^name;
                next unless $native.starts-with('LibTmux') || $native.starts-with('X::LibTmux')
                    || $value.HOW.^name.contains('EnumHOW');
                %types{$native} = $value;
                %aliases{$name ~ '::' ~ $export} = $native;
            }
        }
    }
    for @VALUES -> $name { %types{$name} = ::($name) }
    sub errors($type) {
        %types{$type.^name} = $type;
        for $type.WHO.values -> $child {
            errors($child) if !$child.DEFINITE && $child.^isa(::('X::LibTmux'));
        }
    }
    errors(::('X::LibTmux'));
    my @types;
    for %types.sort(*.key) -> $entry {
        my @methods;
        if $entry.value.HOW.^can('methods') {
            for $entry.value.^methods(:all) -> $method {
                next unless $method ~~ Method && !$method.name.starts-with('!');
                next unless $method.file.contains('LibTmux');
                @methods.push(%(name => $method.name, file => $method.file, line => $method.line));
            }
        }
        @types.push(%(id => $entry.key, methods => @methods));
    }
    %(types => @types, aliases => %aliases, functions => @functions)
}

multi sub MAIN(Str:D :$unit!) { say to-json(extract-unit($unit), :!pretty) }
multi sub MAIN(Bool:D :$surface!) { say to-json(runtime-surface(), :!pretty) }
# Internal fixture entry point: published artifacts omit this native extraction metadata.
multi sub MAIN(Str:D :$check-links!) {
    my %artifact = from-json($check-links.IO.slurp);
    validate-links(%artifact<symbols>.List, (%artifact<aliases> // {}).Hash);
    say 'Validated native documentation links';
}
multi sub MAIN(Str:D :$output = 'docs/_build/api.json') {
    my $revision = command('git', 'rev-parse', 'HEAD');
    my $meta-hash = input-hashes(['META6.json'])<META6.json>;
    my %meta = from-json('META6.json'.IO.slurp);
    my @files = %meta<provides>.values.unique.sort;
    my @resources = %meta<resources>.map({ 'resources/' ~ $_ });
    my @examples = 'examples'.IO.dir.grep(*.extension eq 'raku').map(*.Str).sort;
    my $catalogue-guide = 'docs/reference/catalogue.rakudoc';
    my @inputs = 'META6.json', '.tool-versions', |@files, |@resources, |@examples, $catalogue-guide;
    my %hashes = input-hashes([|@inputs, $*PROGRAM-NAME]);
    die 'Metadata changed during documentation extraction' unless %hashes<META6.json> eq $meta-hash;
    my @declarations;
    my %guides;
    my %guide-links;
    for @files -> $file {
        my %unit = from-json(command($*EXECUTABLE.Str, '-I.', $*PROGRAM-NAME, "--unit=$file"));
        @declarations.append(|%unit<declarations>);
        my $module = %meta<provides>.keys.first({ %meta<provides>{$_} eq $file });
        %guides{$module} = %unit<guide> if %unit<guide>.chars;
        %guide-links{$module} = %unit<guideLinks>;
    }
    my %surface = from-json(command($*EXECUTABLE.Str, '-I.', $*PROGRAM-NAME, '--surface'));
    my %by-id;
    for @declarations -> %declaration {
        my $id = %declaration<id>;
        if %by-id{$id}:exists {
            %by-id{$id}<signatures>.append(|%declaration<signatures>);
        } else { %by-id{$id} = %declaration }
    }
    for @declarations -> %declaration {
        for %declaration<signatures>.List -> %signature {
            my @resolved;
            for (%signature<references> // []).List -> %reference {
                my $target = %reference<target>;
                unless %by-id{$target}:exists {
                    my @matching = @declarations.grep({ .<name> eq $target && .<kind> eq 'enum' });
                    next unless @matching || $target.starts-with('LibTmux') || $target.starts-with('X::LibTmux');
                    die "Ambiguous native enum reference $target" unless @matching.elems == 1;
                    %reference<target> = @matching[0]<id>;
                }
                @resolved.push(%reference);
            }
            %signature<references> = @resolved;
        }
    }
    my %public;
    my %missing;
    sub include(%symbol) {
        my %entry = %symbol;
        %entry<apiScope> = 'exported'; %entry<product> = 'core'; %entry<package> = %meta<name>;
        %entry<publicId> = %entry<id>;
        %entry<doc> = %(summary => '', body => %guides{%entry<id>},
            _nativeLinks => %guide-links{%entry<id>}) if %guides{%entry<id>}:exists;
        %missing{%entry<id>} = %entry<source> unless %entry<doc><summary> || %entry<doc><body>;
        %public{%entry<id>} = %entry;
    }
    for %surface<types>.List -> %type {
        my $id = %type<id>;
        unless %by-id{$id}:exists {
            my @matching = @declarations.grep({ .<name> eq $id && .<kind> eq 'enum' });
            if @matching.elems == 1 {
                for %surface<aliases>.keys -> $alias {
                    %surface<aliases>{$alias} = @matching[0]<id> if %surface<aliases>{$alias} eq $id;
                }
                $id = @matching[0]<id>;
            }
        }
        next unless %by-id{$id}:exists;
        include(%by-id{$id});
        for @declarations.grep({ (.<parent> // '') eq $id && .<kind> eq any(<method property constant>) }) -> %member {
            include(%member);
        }
        for %type<methods>.List -> %method {
            my $member-id = $id ~ '.' ~ %method<name>;
            next if %public{$member-id}:exists;
            my $file = %method<file>.split(' (')[0].IO.relative($*CWD);
            my $source = @declarations.first({ .<name> eq %method<name>
                && .<source><file> eq $file && .<source><line> == %method<line> });
            next unless $source.defined;
            my %inherited = |$source, id => $member-id, parent => $id, inheritedFrom => $source<parent>;
            include(%inherited);
        }
    }
    for %surface<functions>.List -> %function {
        my $id = %function<module> ~ '.' ~ %function<name>;
        include(%by-id{$id}) if %by-id{$id}:exists;
    }
    loop {
        my %targets;
        for %public.values -> %entry {
            for (%entry<extends> // []).List -> $base {
                %targets{$base} = True if $base ne 'Exception' && !(%public{$base}:exists);
            }
            for %entry<signatures>.List -> %signature {
                for (%signature<references> // []).List -> %reference {
                    %targets{%reference<target>} = True unless %public{%reference<target>}:exists;
                }
            }
        }
        my @targets = %targets.keys;
        last unless @targets;
        for @targets -> $id {
            die "Public signature exposes internal acquisition type $id"
                if $id eq any(<LibTmux::Engine::Runtime LibTmux::Engine::Acquirer>);
            die "Native signature target has no declaration: $id" unless %by-id{$id}:exists;
            include(%by-id{$id});
            for @declarations.grep({ (.<parent> // '') eq $id && .<kind> eq any(<method property constant>) }) -> %member {
                include(%member);
            }
        }
    }
    # Keep module documentation and ownership even when its implementation is internal.
    for %public.values.List -> %symbol {
        my $parent = %symbol<parent> // '';
        include(%by-id{$parent}) if $parent.chars && !(%public{$parent}:exists) && (%by-id{$parent}:exists);
    }
    my %catalogue = from-json(command($*EXECUTABLE.Str, '-I.', $*PROGRAM-NAME, "--unit=$catalogue-guide"));
    %public<LibTmux::Catalogue><doc><body> ~= "\n\n" ~ %catalogue<guide>;
    %public<LibTmux::Catalogue><doc><_nativeLinks>.append(|%catalogue<guideLinks>);
    my $dirty = so command('git', 'status', '--porcelain', '--', |@inputs).chars;
    my $exporter-dirty = so command('git', 'status', '--porcelain', '--', $*PROGRAM-NAME).chars;
    my @symbols = %public.values.sort(*.<id>).Array;
    for @symbols -> %symbol {
        if !%symbol<parent> && %symbol<id> ne 'LibTmux' {
            my $namespace = %symbol<id>.split('::')[0..*-2].join('::');
            %symbol<parent> = %public{$namespace}:exists ?? $namespace !! 'LibTmux';
        }
        %symbol<source><revision> = $revision;
        %symbol<inheritedFrom>:delete if %symbol<inheritedFrom>
            && !(%public{%symbol<inheritedFrom>}:exists);
        %symbol<modifiers>.push('overload') if %symbol<signatures>.elems > 1;
        %symbol<doc>:delete unless %symbol<doc>.elems;
    }
    validate-links(@symbols, %surface<aliases>);
    for @symbols -> %symbol {
        %symbol<doc><_nativeLinks>:delete if %symbol<doc>.defined;
        for %symbol<signatures>.List -> %signature {
            %signature<doc><_nativeLinks>:delete if %signature<doc>.defined;
        }
    }
    my @groups = @symbols.grep(*.<kind> eq 'module').map(-> %module {
        %(owner => %module<id>, title => 'Public declarations', members =>
            @symbols.grep({ (.<parent> // '') eq %module<id> }).map(*.<id>).Array)
    });
    my %artifact = schema => 'libtmux.raku-api/v1', port => 'raku',
        repo => 'libtmux/libtmux-raku', :$revision, workingTree => $dirty,
        compiler => $*RAKU.compiler.version.Str, language => %meta<raku>,
        extractor => 'Rakudo RakuAST and RakuDoc/v1',
        aliases => %surface<aliases>, symbols => @symbols, exportGroups => @groups,
        nativeProvenance => %(
            library => %(repository => 'libtmux/libtmux-raku', :$revision, workingTree => $dirty),
            files => @inputs.map({ %(path => $_, sha256 => %hashes{$_}) }).Array,
            exporter => %(name => 'RakuAST and RakuDoc export', version => 1,
                repository => 'libtmux/libtmux-raku', :$revision, path => $*PROGRAM-NAME,
                sha256 => %hashes{$*PROGRAM-NAME}, workingTree => $exporter-dirty),
        ),
        generatedSources => (|@files, |@examples).map({ $_ => .IO.slurp }).Hash,
        missingDocumentation => %missing;
    die 'Inputs changed during documentation extraction; rerun from stable source'
        unless input-hashes([|@inputs, $*PROGRAM-NAME]) eqv %hashes
            && command('git', 'rev-parse', 'HEAD') eq $revision;
    $output.IO.parent.mkdir(:parents);
    $output.IO.spurt(to-json(%artifact, :sorted-keys) ~ "\n");
    note "Exported {@symbols.elems} declarations; {%missing.elems} need documentation";
}
