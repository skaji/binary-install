package App;
use v5.20;
use warnings;
use experimental qw(lexical_subs signatures postderef);

use Digest::MD5 ();
use File::Basename qw(basename dirname);
use File::Copy ();
use File::Find ();
use File::Path ();
use File::Spec;
use File::Temp ();
use File::Which ();
use File::pushd qw(pushd);
use GitHub::Release;
use HTTP::Tinyish;
use IPC::Run3 ();
use JSON::PP ();
use POSIX ();
use Parallel::Pipes::App;
use YAML::PP;

use constant DEBUG => $ENV{DEBUG} ? 1 : 0;

my sub catpath (@argv) { File::Spec->catfile(@argv) }

my $TAR = qr/\.(?:tgz|tar\.(?:gz|bz2|xz))$/;
my $ZIP = qr/\.zip$/;
my $ARCHIVE = qr/(?:$TAR|$ZIP)/;

my $GIT = File::Which::which("git");
my $GO = File::Which::which("go");
my $JAVA = File::Which::which("java");
my $LOG_GO = "\e[1;35mGO!\e[m";
my $LOG_DONE = "\e[1;35mDONE!\e[m";

sub new ($class) {
    my $home = (<~>)[0];
    my $base_dir = catpath $home, ".binary-install";
    my $cache_dir = catpath $base_dir, "cache";
    my $work_dir = catpath $base_dir, "work";
    my $jar_dir = catpath $base_dir, "jar";
    my $go_dir = catpath $base_dir, "go";
    File::Path::mkpath $_ for $base_dir, $cache_dir, $work_dir, $jar_dir, $go_dir;

    my $os = $^O =~ /linux/i ? "linux" : $^O =~ /darwin/i ? "darwin" : die;
    my $_arch = (POSIX::uname)[4];
    my %arch = (
        amd64   => "amd64",
        x86_64  => "amd64",
        arm64   => "arm64",
        aarch64 => "arm64",
    );
    my $arch = $arch{$_arch} or die "unsupported arch: $_arch";
    bless {
        os => $os,
        arch => $arch,
        home => $home,
        work_dir => $work_dir,
        cache_dir => $cache_dir,
        jar_dir => $jar_dir,
        go_dir => $go_dir,
        http => HTTP::Tinyish->new(verify_SSL => 1),
        github_release => GitHub::Release->new,
        _workers => {},
    }, $class;
}

sub run_with_log ($self, $name, @cmd) {
    $self->log($name, "@cmd");
    my $pid = open my $fh, "-|";
    if ($pid == 0) {
        open STDERR, ">&", \*STDOUT;
        exec { $cmd[0] } @cmd;
        exit 1;
    }
    while (<$fh>) {
        $self->log($name, $_);
    }
    close $fh;
    $? == 0;
}

sub log ($self, $name, $msg) {
    chomp $msg;
    warn "[\e[1;32m$name\e[m] $msg\n";
}

sub download ($self, $url) {
    my $md5 = substr Digest::MD5::md5_hex($url), 0, 8;
    my $local_file = catpath $self->{cache_dir}, $md5 . "-" . basename($url);
    my $res = $self->{http}->mirror($url => $local_file);
    die "$res->{status}, $url\n" if !$res->{success};
    $local_file;
}

sub http_get ($self, $url) {
    my $res = $self->{http}->get($url);
    die "$res->{status}, $url\n" if !$res->{success};
    $res->{content};
}

sub unpack ($self, $archive) {
    my $tempdir = File::Temp::tempdir
        TEMPLATE => "unpack-XXXXX",
        CLEANUP => 0,
        DIR => $self->{work_dir},
    ;
    my $guard = pushd $tempdir;
    if ($archive =~ $TAR) {
        !system "tar", "xf", $archive or die;
    } elsif ($archive =~ $ZIP) {
        !system "unzip", "-q", $archive or die;
    } else {
        die;
    }
    $tempdir;
}

sub cleanup ($self) {
    opendir my ($dh), $self->{work_dir} or die;
    my $one_week_ago = time - 7*24*60*60;
    my @obsolete =
        grep { (stat $_)[9] < $one_week_ago }
        map { catpath $self->{work_dir}, $_ }
        grep { /^unpack-/ }
        readdir $dh
    ;
    closedir $dh;
    for my $dir (@obsolete) {
        warn "Remove $dir\n";
        File::Path::rmtree $dir;
    }
}

sub probe_github_release ($self, @release) {
    my $exclude = qr/\.(?:rpm|deb|txt|sha256|json)$/;
    my ($want_os, $want_archs);
    if ($self->{os} eq "linux") {
        $want_os = qr/linux/i;
    } else {
        $want_os = qr/(?:darwin|macos|osx)/i;
    }
    if ($self->{arch} eq "amd64") {
        $want_archs = [qr/(?:amd64|x86_64)/i, qr/64/, qr/all/i, qr/universal/i];
    } else {
        $want_archs = [qr/(?:arm64|AArch64)/i, qr/(?:amd64|x86_64)/i, qr/64/, qr/all/i, qr/universal/i];
    }

    my @candidate;
    for my $i (0 .. $want_archs->$#*) {
        my $want_arch = $want_archs->[$i];
        for my $release (@release) {
            DEBUG and $i == 0 and warn $release;
            my $file = $release =~ s{.*/releases/download/}{}r;
            if ($file =~ $exclude) {
                next;
            }
            if ($file =~ $want_os && $file =~ $want_arch) {
                push @candidate, $release;
            }
        }
        last if @candidate;
    }
    if (!@candidate) {
        warn "---> $_\n" for @release;
        die "cannot probe release";
    }
    my $sort_by = sub ($a, $b) {
        if ($b =~ $ARCHIVE && $a =~ $ARCHIVE) {
            return 0;
        } elsif ($b =~ $ARCHIVE) {
            return 1;
        } elsif ($a =~ $ARCHIVE) {
            return -1;
        } else {
            return 0;
        }
    };
    (sort { $sort_by->($b, $a) } @candidate)[0];
}

sub probe_local_version ($self, $target, $version_regexp = undef) {
    if ($target =~ /kubectl$/) {
        IPC::Run3::run3 [$target, qw(version --client --output json)], \undef, \my $out, undef;
        my $v = JSON::PP::decode_json $out;
        return $v->{clientVersion}{gitVersion};
    }
    for my $option (qw(--version version -v -V --help help -h)) {
        my $out;
        IPC::Run3::run3 [$target, $option], \undef, \$out, \$out, { return_if_system_error => 1 };
        if ($? == -1) {
            DEBUG and warn "$target $option: $out";
            return;
        }
        if ($? == 0) {
            if ($version_regexp) {
                if ($out =~ /$version_regexp/) {
                    return $1;
                }
            } else {
                if ($out =~ /(\d+\.\d+\.\d+)/) {
                    return $1;
                } elsif ($out =~ /(\d+\.\d+)/) {
                    return $1;
                }
            }
        }
        DEBUG and warn "$target $option: $out\n";
    }
    die "cannot probe version: $target";
}

sub probe_binary_in_dir ($self, $name, $dir) {
    my $guard = pushd $dir;
    my @candidate;
    File::Find::find({no_chdir => 1, wanted => sub () {
        my $file = $_;
        DEBUG and warn $file;
        return if !-f $file;
        my $size = (stat $file)[7];
        if (basename($file) eq $name) {
            push @candidate, { file => $file, size => $size + 1_000_000_000 };
        } elsif (-x $file) {
            push @candidate, { file => $file, size => $size };
        }
    }}, ".");
    @candidate = sort { $b->{size} <=> $a->{size} } @candidate;
    if (@candidate) {
        return catpath $dir, $candidate[0]{file};
    }
    die "cannot find binary";
}

sub resolve_target ($self, $path) {
    my $target = $self->resolve_home($path);
    $self->resolve_shell($target);
}

sub resolve_home ($self, $path) {
    $path =~ s/^~/$self->{home}/r;
}

sub resolve_shell ($self, $path) {
    return $path if $path !~ /\$/;

    my $fail;
    my $env = sub ($name) {
        return $name if exists $ENV{$name};
        $fail = "missing env $name";
        return "";
    };
    my $cmd = sub ($shell) {
        my $out = `$shell`;
        if ($? != 0) {
            $fail = "failed: $shell";
            return;
        }
        chomp $out;
        $out;
    };
    $path =~ s/\$\{?([A-Za-z0-9_]+)\}?/$env->($1)/eg;
    $path =~ s/\$\(([^\)]+)\)/$cmd->($1)/eg;
    return $path, $fail;
}

sub _binary_install ($self, $spec, $probe_latest_version, $probe_latest_url) {
    my $name = $spec->{name};
    my ($target, $resolve_fail) = $self->resolve_target($spec->{target});
    if ($resolve_fail) {
        $self->log($name, $resolve_fail);
        return 1;
    }

    if (-e $target and my $local_version = $self->probe_local_version($target, $spec->{version_regexp})) {
        my $latest_version = $probe_latest_version->($spec);
        if ($latest_version =~ /$local_version/) {
            $self->log($name, "You have $local_version, latest_version $latest_version, OK");
            return 1;
        }
        $self->log($name, "You have $local_version, latest_version $latest_version, $LOG_GO");
    } else {
        $self->log($name, "You don't have one, $LOG_GO");
    }

    my $latest_url = $probe_latest_url->($spec);
    $self->log($name, "Downloading $latest_url");
    my $local_file = $self->download($latest_url);
    my $binary = $local_file;
    if ($local_file =~ $ARCHIVE) {
        my $dir = $self->unpack($local_file);
        $binary = $self->probe_binary_in_dir($name, $dir);
    }
    {
        my $dir = dirname $target;
        if (!-e $dir) {
            File::Path::mkpath $dir;
        }
    }
    $self->log($name, "Install $binary as $target");
    {
        my $tmp = "$target.tmp";
        File::Copy::copy $binary, $tmp or die "copy $binary, $tmp: $!";
        chmod 0755, $tmp or die;
        rename $tmp, $target or die "rename $tmp, $target: $!";
    }
    1;
}

sub github_install ($self, $spec) {
    my $probe_latest_version = sub ($spec) {
        if (my $version_regexp = $spec->{version_regexp}) {
            my @tag = $self->{github_release}->get_tags($spec->{url});
            @tag = grep { /$version_regexp/ } @tag;
            return $tag[0];
        }
        $self->{github_release}->get_latest_tag($spec->{url});
    };
    my $probe_latest_url = sub ($spec) {
        my $latest_version = $probe_latest_version->($spec);
        my @release = $self->{github_release}->get_assets($spec->{url}, $latest_version);
        $self->probe_github_release(@release);
    };
    $self->_binary_install($spec, $probe_latest_version, $probe_latest_url);
}

sub kubectl_install ($self, $spec) {
    my $probe_latest_version = sub ($spec) {
        $self->http_get("https://dl.k8s.io/release/stable.txt");
    };
    my $probe_latest_url = sub ($spec) {
        my $version = $self->http_get("https://dl.k8s.io/release/stable.txt");
        "https://dl.k8s.io/release/$version/bin/$self->{os}/$self->{arch}/kubectl";
    };
    $self->_binary_install($spec, $probe_latest_version, $probe_latest_url);
}

sub spin_install ($self, $spec) {
    my $probe_latest_version = sub ($spec) {
        my $version = $self->http_get("https://storage.googleapis.com/spinnaker-artifacts/spin/latest");
        chomp $version;
        $version;
    };
    my $probe_latest_url = sub ($spec) {
        my $version = $self->http_get("https://storage.googleapis.com/spinnaker-artifacts/spin/latest");
        chomp $version;
        "https://storage.googleapis.com/spinnaker-artifacts/spin/$version/$self->{os}/$self->{arch}/spin";
    };
    $self->_binary_install($spec, $probe_latest_version, $probe_latest_url);
}

sub helm_install ($self, $spec) {
    my $url = "https://github.com/helm/helm";
    my $probe_latest_version = sub ($spec) {
        $self->{github_release}->get_latest_tag($url);
    };
    my $probe_latest_url = sub ($spec) {
        my $version = $self->{github_release}->get_latest_tag($url);
        "https://get.helm.sh/helm-$version-$self->{os}-$self->{arch}.tar.gz";
    };
    $self->_binary_install($spec, $probe_latest_version, $probe_latest_url);
}

sub git_install ($self, $spec) {
    my $name = $spec->{name};
    if (!$GIT) {
        $self->log($name, "need git, skip");
        return;
    }
    my ($target, $resolve_fail) = $self->resolve_target($spec->{target});
    if ($resolve_fail) {
        $self->log($name, $resolve_fail);
        return 1;
    }
    my $url = $spec->{url};
    my $ref = $spec->{ref};
    if (-e $target) {
        my $guard = pushd $target;
        if ($ref) {
            $self->run_with_log($name, $GIT, "fetch") or die;
            $self->run_with_log($name, $GIT, "checkout", $ref) or die;
        } else {
            $self->run_with_log($name, $GIT, "pull") or die;
        }
    } else {
        $self->run_with_log($name, $GIT, "clone", $url, $target) or die;
        if ($ref) {
            $self->run_with_log($name, $GIT, "checkout", $ref) or die;
        }
    }
}

sub go_install ($self, $spec) {
    my $name = $spec->{name};
    if (!$GO) {
        $self->log($name, "need go, skip");
        return;
    }
    my ($target, $resolve_fail) = $self->resolve_target($spec->{target});
    if ($resolve_fail) {
        $self->log($name, $resolve_fail);
        return 1;
    }
    if (-e $target) {
        IPC::Run3::run3 [$GO, "version"], undef, \my $out1, undef;
        my ($go_version) = $out1 =~ /go([0-9.]+)/;
        IPC::Run3::run3 [$GO, "version", $target], undef, \my $out2, undef;
        my ($target_version) = $out2 =~ /go([0-9.]+)/;
        if ($go_version eq $target_version) {
            $self->log($name, "You already have it, and it is built with go $go_version, OK");
            return 1;
        }
        $self->log($name, "You have it (built with go $target_version), $LOG_GO");
    } else {
        $self->log($name, "You don't have one, $LOG_GO");
    }
    my $package = $spec->{package};
    my $target_dir = dirname $target;
    local %ENV = (%ENV, GOBIN => $target_dir);
    my $guard = pushd $self->{go_dir};
    $self->run_with_log($name, $GO, "install", $package) or die;
}

sub github_jar_install ($self, $spec) {
    my $name = $spec->{name};
    if (!$JAVA) {
        $self->log($name, "need java, skip");
        return;
    }
    my ($target, $resolve_fail) = $self->resolve_target($spec->{target});
    if ($resolve_fail) {
        $self->log($name, $resolve_fail);
        return 1;
    }
    my $url = $spec->{url};
    if (-e $target and my $local_version = $self->probe_local_version($target)) {
        my $latest_tag = $self->{github_release}->get_latest_tag($url);
        if ($latest_tag =~ /$local_version/) {
            $self->log($name, "You have $local_version, latest_tag $latest_tag, OK");
            return 1;
        }
        $self->log($name, "You have $local_version, latest_tag $latest_tag, $LOG_GO");
    } else {
        $self->log($name, "You don't have one, $LOG_GO");
    }

    my @release = $self->{github_release}->get_latest_assets($url);
    my ($release) = grep { /all-deps\.jar$/ } @release;
    if (!$release) {
        die "cannot find all-deps.jar in @release";
    }
    $self->log($name, "Downloading $release");
    my $jar_target = catpath $self->{jar_dir}, basename($release);
    my $res = $self->{http}->mirror($release => $jar_target);
    die "$res->{status}, $release" if !$res->{success};

    open my $fh, ">", $target or die;
    say {$fh} qq[#!/bin/bash];
    say {$fh} qq[exec java -jar $jar_target "\$@"];
    close $fh;
    chmod 0755, $target or die;
}

sub run ($self, $file) {
    die "Usage: binary-install spec.yaml\n" if !$file or !-f $file;

    my ($yaml) = YAML::PP->new->load_file($file);

    my @task;
    for my $type (sort keys %$yaml) {
        if (!$self->can("${type}_install")) {
            warn "WARN: unknown type $type, skip\n";
            next;
        }
        for my $spec ($yaml->{$type}->@*) {
            next if exists $spec->{enabled} && !$spec->{enabled};
            if ($spec->{only}) {
                my $ok;
                for my $os_arch (split /\s*,\s*/, $spec->{only}) {
                    my ($os, $arch) = split m{/}, $os_arch;
                    if ($os eq $self->{os} and (!$arch or $arch eq $self->{arch})) {
                        $ok++, last;
                    }
                }
                next if !$ok;
            }
            my $priority = $spec->{priority} || 0;
            push @task, { type => $type, spec => $spec, priority => $priority };
        }
    }
    @task = sort { $a->{priority} <=> $b->{priority} } @task;
    my $work = sub ($task) {
        local $0 = "$0 ($task->{spec}{name})";
        my $method = "$task->{type}_install";
        eval { $self->$method($task->{spec}) };
        warn $@ if $@;
        $task;
    };
    Parallel::Pipes::App->run(
        num => 2,
        work => $work,
        tasks => \@task,
        before_work => sub ($task, $worker) {
            $task->{_start} = time;
            $self->{_workers}{$worker->{pid}} = $task->{spec}{name};
        },
        after_work => sub ($task, $worker) {
            my $diff = time - $task->{_start};
            if ($diff > 5) {
                $self->log($task->{spec}{name}, $LOG_DONE);
            }
            delete $self->{_workers}{$worker->{pid}};
        },
        idle_tick => 5,
        idle_work => sub () {
            if (my @name = sort values $self->{_workers}->%*) {
                $self->log($_, "Still running...") for @name;
            }
        },
    );
    $self->cleanup;
}

1;
