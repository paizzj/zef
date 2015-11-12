use Zef::Authority;
use Zef::Utils::Depends;
use Zef::Utils::Git;

# XXX Authority:: modules will be getting replaced with Storage (or Storage related modules)

my @skip = <v6 MONKEY-TYPING MONKEY_TYPING strict fatal nqp NativeCall cur lib Test>;

# perl6 community ecosystem + test reporting
class Zef::Authority::P6C does Zef::Authority {
    has $!git     = Zef::Utils::Git.new;

    # Use the p6c hosted projects.json to get a list of name => git-repo that 
    # can then be fetched with Utils::Git
    method get(
        Zef::Authority::P6C:D: 
        *@wants,
        :@ignore,
        :$save-to is copy,
        Bool :$depends,
        Bool :$test-depends,
        Bool :$build-depends,
        Bool :$fetch = True,
    ) {

        my @explicit-wants = @!projects.grep({ $_.<name> ~~ any(@wants) }).cache;

        # implicit meaning the user expects us to try to turn module names into distro names if needed
        my @implicit-wants = @!projects\
            .grep({ $_.<name> !~~ @explicit-wants }).grep({ $_.<provides> })\
            .grep( -> $dist { any($dist.<provides>.hash.keys) ~~ any(@wants) }).cache;

        my @still-missing = @wants.grep: {$_ ~~ none(@explicit-wants>><name>, @implicit-wants>><name>)}
        my @implicit-deps = @!projects.grep({ $_<name> ~~ any(@still-missing) });

        my @wants-dists = unique flat @explicit-wants, @implicit-wants, @implicit-deps;

        my @wants-dists-filtered = !@ignore ?? @wants-dists !! @wants-dists.grep({
               (!$depends       || any($_.<depends>.grep(*.so))       ~~ none(@ignore.grep(*.so)))
            && (!$test-depends  || any($_.<build-depends>.grep(*.so)) ~~ none(@ignore.grep(*.so)))
            && (!$build-depends || any($_.<test-depends>.grep(*.so))  ~~ none(@ignore.grep(*.so)))
        });

        return [] unless @wants-dists-filtered;

        # Determine the distribution dependencies we want/need
        my $levels = ?$depends
            ?? Zef::Utils::Depends.new(:@!projects).topological-sort( @wants-dists-filtered, 
                :$depends, :$build-depends, :$test-depends)
            !! @wants-dists-filtered.map({ $_.hash.<name> });

        # Try to fetch each distribution dependency
        my %cache;
        eager gather for $levels.cache -> $level {
            for $level.cache -> $package-name {
                next if $package-name.lc ~~ any(@skip>>.lc);

                # todo: filter projects by version/auth
                my %dist = @!projects.cache.first({ $_.<name>.lc eq $package-name.lc }).hash;
                unless %dist.keys {
                    %dist = @!projects.cache.first({ $package-name eq any($_.<provides>.hash.keys) });
                }
                die "!!!> No source-url for $package-name (META info lost?)" and next unless ?%dist<source-url>;
                next if ?%cache{%dist<name>}; # hack to prevent reinstalling implied and reundant deps (ala URI, URI::Encoded)
                %cache{%dist<name>} = $package-name;

                # todo: implement the rest of however github.com transliterates paths
                my $basename  = %dist<name>.trans(':' => '-');
                temp $save-to = ~$save-to.IO.child($basename);
                my @git       = $!git.clone(:$save-to, %dist<source-url>).cache;

                take %( :unit-id(%dist.<name>), :path(@git.[0].<path>), :ok(?$save-to.IO.e) )
            }
        }
    }

    # todo: refactor into Zef::Roles::
    method report(*@metas, :@test-results, :@build-results) {
        eager gather for @metas -> $meta-path {
            my $meta-json = from-json($meta-path.IO.slurp);
            my %meta      = %($meta-json);
            my $repo-path = $meta-path.IO.parent;

            my $test  = @test-results>>.first({ $_.path.IO.ACCEPTS($repo-path.IO) }).first(*.so);
            my $build = @build-results>>.first({ $_.path.IO.ACCEPTS($repo-path.IO) }).first(*.so);

            my sub output($d) {
                my $out;
                for $d.processes -> @group {
                    for @group -> $proc {
                        with $proc.stdmerge -> $o {
                            $out ~= $o;
                        }
                    }
                }
                $out;
            }

            # Now that the same Distribution object is used for building and testing we need to find
            # a way to separate the output of different phases. Currently $build-output's value will
            # be the actual build value if --no-tests, or the same as $test-output otherwise (or whatever is last)
            my $build-output;  # ?$build ?? output($build) !! '';
            my $build-passed = True; # ?$build ?? ?(?$build.passes.elems && !$build.failures.elems) !! Nil;

            my $test-output  = ?$test  ?? output($test)  !! '';
            my $test-passed  = ?$test  ?? ?(?$test.passes.elems && !$test.failures.elems) !! Nil;

            my $report = to-json %(
                :name(%meta<name>),
                :version(%meta<ver> // %meta<version> // '*'),
                :dependencies(%meta<depends>),
                :metainfo($meta-json),
                :build-output($build-output),
                :test-output($test-output),
                :build-passed($build-passed),
                :test-passed($test-passed),
                :distro(%(
                    :name($*DISTRO.name),
                    :version($*DISTRO.version.Str),
                    :auth($*DISTRO.auth),
                    :release($*DISTRO.release),
                )),
                :kernel(%(
                    :name($*KERNEL.name),
                    :version($*KERNEL.version.Str),
                    :auth($*KERNEL.auth),
                    :release($*KERNEL.release),
                    :hardware($*KERNEL.hardware),
                    :arch($*KERNEL.arch),
                    :bits($*KERNEL.bits),
                )),
                :perl(%(
                    :name($*PERL.name),
                    :version($*PERL.version.Str),
                    :auth($*PERL.auth),
                    :compiler(%(
                        :name($*PERL.compiler.name),
                        :version($*PERL.compiler.version.Str),
                        :auth($*PERL.compiler.auth),
                        :release($*PERL.compiler.release),
                        :build-date($*PERL.compiler.build-date.Str),
                        :codename($*PERL.compiler.codename),
                    )),
                )),
                :vm(%(
                    :name($*VM.name),
                    :version($*VM.version.Str),
                    :auth($*VM.auth),
                    :config($*VM.config),
                    :properties($*VM.?properties),
                    :precomp-ext($*VM.precomp-ext),
                    :precomp-target($*VM.precomp-target),
                    :prefix($*VM.prefix.Str),
                )),
            );

            my $report-id = try {
                CATCH { default { print "===> Error while POSTing: $_" }}
                my $response = die "Temproarily disabled while rakudo newline support is worked on"; #$!ua.post("http://testers.perl6.org/report", :body($report));
                my $body     = $response.content(:bin).decode('utf-8');
                ?$body.match(/^\d+$/) ?? $body.match(/^\d+$/).Str !! 0;
            } // '';

            take %( :ok(?$report-id), :unit-id(%meta<name>), :$report, :$report-id );
        }
    }
}
