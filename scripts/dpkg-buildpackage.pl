#!/usr/bin/perl
#
# dpkg-buildpackage
#
# Copyright © 1996 Ian Jackson
# Copyright © 2000 Wichert Akkerman
# Copyright © 2006-2010, 2012-2015 Guillem Jover <guillem@debian.org>
# Copyright © 2007 Frank Lichtenheld
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

use strict;
use warnings;

use Cwd;
use File::Temp qw(tempdir);
use File::Basename;
use File::Copy;
use POSIX qw(:sys_wait_h);

use Dpkg ();
use Dpkg::Gettext;
use Dpkg::ErrorHandling;
use Dpkg::Build::Types;
use Dpkg::BuildOptions;
use Dpkg::BuildProfiles qw(set_build_profiles);
use Dpkg::Conf;
use Dpkg::Compression;
use Dpkg::Checksums;
use Dpkg::Package;
use Dpkg::Version;
use Dpkg::Control;
use Dpkg::Control::Info;
use Dpkg::Changelog::Parse;
use Dpkg::Path qw(find_command);
use Dpkg::IPC;

textdomain('dpkg-dev');

sub showversion {
    printf g_("Debian %s version %s.\n"), $Dpkg::PROGNAME, $Dpkg::PROGVERSION;

    print g_('
This is free software; see the GNU General Public License version 2 or
later for copying conditions. There is NO warranty.
');
}

sub usage {
    printf g_(
'Usage: %s [<option>...]')
    . "\n\n" . g_(
'Options:
      --build=<type>[,...]    specify the build <type>: full, source, binary,
                                any, all (default is \'full\').
  -F                          normal full build (source and binary; default).
  -g                          source and arch-indep build.
  -G                          source and arch-specific build.
  -b                          binary-only, no source files.
  -B                          binary-only, only arch-specific files.
  -A                          binary-only, only arch-indep files.
  -S                          source-only, no binary files.
  -nc, --no-pre-clean         do not pre clean source tree (implies -b).
       --pre-clean            pre clean source tree (default).
  -tc, --post-clean           clean source tree when finished.
  -D                          check build dependencies and conflicts (default).
  -d                          do not check build dependencies and conflicts.
      --[no-]check-builddeps  ditto.
      --ignore-builtin-builddeps
                              do not check builtin build dependencies.
  -P, --build-profiles=<profiles>
                              assume comma-separated build profiles as active.
  -R, --rules-file=<rules>    rules file to execute (default is debian/rules).
  -T, --rules-target=<target> call debian/rules <target>.
      --as-root               ensure -T calls the target with root rights.
  -j, --jobs[=<number>|auto]  jobs to run simultaneously (passed to <rules>),
                                forced mode.
  -J, --jobs-try[=<number>|auto]
                              jobs to run simultaneously (passed to <rules>),
                                opt-in mode (default is auto).
  -r, --root-command=<command>
                              command to gain root rights (default is fakeroot).
      --check-command=<command>
                              command to check the .changes file (no default).
      --check-option=<opt>    pass <opt> to check <command>.
      --hook-<name>=<command> set <command> as the hook <name>, known hooks:
                                init preclean source build binary buildinfo
                                changes postclean check sign done
      --buildinfo-option=<opt>
                              pass option <opt> to dpkg-genbuildinfo.
  -p, --sign-command=<command>
                              command to sign .dsc and/or .changes files
                                (default is gpg2 or gpg).
  -k, --sign-key=<keyid>      the key to use for signing.
  -ap, --sign-pause           add pause before starting signature process.
  -us, --unsigned-source      unsigned source package.
  -ui, --unsigned-buildinfo   unsigned .buildinfo file.
  -uc, --unsigned-changes     unsigned .buildinfo and .changes file.
      --no-sign               do not sign any file.
      --force-sign            force signing the resulting files.
      --admindir=<directory>  change the administrative directory.
  -?, --help                  show this help message.
      --version               show the version.')
    . "\n\n" . g_(
'Options passed to dpkg-architecture:
  -a, --host-arch <arch>      set the host Debian architecture.
  -t, --host-type <type>      set the host GNU system type.
      --target-arch <arch>    set the target Debian architecture.
      --target-type <type>    set the target GNU system type.')
    . "\n\n" . g_(
'Options passed to dpkg-genchanges:
  -si                         source includes orig, if new upstream (default).
  -sa                         source includes orig, always.
  -sd                         source is diff and .dsc only.
  -v<version>                 changes since version <version>.
  -m, --release-by=<maint>    maintainer for this release is <maint>.
  -e, --build-by=<maint>      maintainer for this build is <maint>.
  -C<descfile>                changes are described in <descfile>.
      --changes-option=<opt>  pass option <opt> to dpkg-genchanges.')
    . "\n\n" . g_(
'Options passed to dpkg-source:
  -sn                         force Debian native source format.
  -s[sAkurKUR]                see dpkg-source for explanation.
  -z, --compression-level=<level>
                              compression level to use for source.
  -Z, --compression=<compressor>
                              compression to use for source (gz|xz|bzip2|lzma).
  -i, --diff-ignore[=<regex>] ignore diffs of files matching <regex>.
  -I, --tar-ignore[=<pattern>]
                              filter out files when building tarballs.
      --source-option=<opt>   pass option <opt> to dpkg-source.
'), $Dpkg::PROGNAME;
}

my $admindir;
my @debian_rules = ('debian/rules');
my @rootcommand = ();
my $signcommand;
my $noclean;
my $cleansource;
my $parallel;
my $parallel_force = 0;
my $checkbuilddep = 1;
my $check_builtin_builddep = 1;
my @source_opts;
my $check_command = $ENV{DEB_CHECK_COMMAND};
my @check_opts;
my $signpause;
my $signkey = $ENV{DEB_SIGN_KEYID};
my $signforce = 0;
my $signreleased = 1;
my $signsource = 1;
my $signbuildinfo = 1;
my $signchanges = 1;
my $buildtarget = 'build';
my $binarytarget = 'binary';
my $host_arch = '';
my $host_type = '';
my $target_arch = '';
my $target_type = '';
my @build_profiles = ();
my @call_target = ();
my $call_target_as_root = 0;
my $since;
my $maint;
my $changedby;
my $desc;
my @buildinfo_opts;
my @changes_opts;
my @hook_names = qw(
    init preclean source build binary buildinfo changes postclean check sign done
);
my %hook;
$hook{$_} = undef foreach @hook_names;


my $conf = Dpkg::Conf->new();
$conf->load_config('buildpackage.conf');

# Inject config options for command-line parser.
unshift @ARGV, @{$conf};

my $build_opts = Dpkg::BuildOptions->new();

if ($build_opts->has('nocheck')) {
    $check_command = undef;
} elsif (not find_command($check_command)) {
    $check_command = undef;
}

while (@ARGV) {
    $_ = shift @ARGV;

    if (/^(?:--help|-\?)$/) {
	usage;
	exit 0;
    } elsif (/^--version$/) {
	showversion;
	exit 0;
    } elsif (/^--admindir$/) {
        $admindir = shift @ARGV;
    } elsif (/^--admindir=(.*)$/) {
	$admindir = $1;
    } elsif (/^--source-option=(.*)$/) {
	push @source_opts, $1;
    } elsif (/^--buildinfo-option=(.*)$/) {
	push @buildinfo_opts, $1;
    } elsif (/^--changes-option=(.*)$/) {
	push @changes_opts, $1;
    } elsif (/^(?:-j|--jobs=)(\d*|auto)$/) {
	$parallel = $1 || '';
	$parallel_force = 1;
    } elsif (/^(?:-J|--jobs-try=)(\d*|auto)$/) {
	$parallel = $1 || '';
	$parallel_force = 0;
    } elsif (/^(?:-r|--root-command=)(.*)$/) {
	my $arg = $1;
	@rootcommand = split /\s+/, $arg;
    } elsif (/^--check-command=(.*)$/) {
	$check_command = $1;
    } elsif (/^--check-option=(.*)$/) {
	push @check_opts, $1;
    } elsif (/^--hook-(.+)=(.*)$/) {
	my ($hook_name, $hook_cmd) = ($1, $2);
	usageerr(g_('unknown hook name %s'), $hook_name)
	    if not exists $hook{$hook_name};
	usageerr(g_('missing hook %s command'), $hook_name)
	    if not defined $hook_cmd;
	$hook{$hook_name} = $hook_cmd;
    } elsif (/^--buildinfo-id=.*$/) {
	# Deprecated option
	warning('--buildinfo-id is deprecated, it is without effect');
    } elsif (/^(?:-p|--sign-command=)(.*)$/) {
	$signcommand = $1;
    } elsif (/^(?:-k|--sign-key=)(.*)$/) {
	$signkey = $1;
    } elsif (/^--(no-)?check-builddeps$/) {
	$checkbuilddep = !(defined $1 and $1 eq 'no-');
    } elsif (/^-([dD])$/) {
	$checkbuilddep = ($1 eq 'D');
    } elsif (/^--ignore-builtin-builddeps$/) {
	$check_builtin_builddep = 0;
    } elsif (/^-s(gpg|pgp)$/) {
	# Deprecated option
	warning(g_('-s%s is deprecated; always using gpg style interface'), $1);
    } elsif (/^--force-sign$/) {
	$signforce = 1;
    } elsif (/^--no-sign$/) {
	$signforce = 0;
	$signsource = 0;
	$signbuildinfo = 0;
	$signchanges = 0;
    } elsif (/^-us$/ or /^--unsigned-source$/) {
	$signsource = 0;
    } elsif (/^-ui$/ or /^--unsigned-buildinfo$/) {
	$signbuildinfo = 0;
    } elsif (/^-uc$/ or /^--unsigned-changes$/) {
	$signbuildinfo = 0;
	$signchanges = 0;
    } elsif (/^-ap$/ or /^--sign-pausa$/) {
	$signpause = 1;
    } elsif (/^-a$/ or /^--host-arch$/) {
	$host_arch = shift;
    } elsif (/^-a(.*)$/ or /^--host-arch=(.*)$/) {
	$host_arch = $1;
    } elsif (/^-P(.*)$/ or /^--build-profiles=(.*)$/) {
	my $arg = $1;
	@build_profiles = split /,/, $arg;
    } elsif (/^-s[iad]$/) {
	push @changes_opts, $_;
    } elsif (/^--(?:compression-level|compression)=.+$/) {
	push @source_opts, $_;
    } elsif (/^--(?:diff-ignore|tar-ignore)(?:=.+)?$/) {
	push @source_opts, $_;
    } elsif (/^-(?:s[nsAkurKUR]|[zZ].*|i.*|I.*)$/) {
	push @source_opts, $_; # passed to dpkg-source
    } elsif (/^-tc$/ or /^--post-clean$/) {
	$cleansource = 1;
    } elsif (/^-t$/ or /^--host-type$/) {
	$host_type = shift; # Order DOES matter!
    } elsif (/^-t(.*)$/ or /^--host-type=(.*)$/) {
	$host_type = $1; # Order DOES matter!
    } elsif (/^--target-arch$/) {
	$target_arch = shift;
    } elsif (/^--target-arch=(.*)$/) {
	$target_arch = $1;
    } elsif (/^--target-type$/) {
	$target_type = shift;
    } elsif (/^--target-type=(.*)$/) {
	$target_type = $1;
    } elsif (/^(?:--target|--rules-target|-T)$/) {
        push @call_target, split /,/, shift @ARGV;
    } elsif (/^(?:--target=|--rules-target=|-T)(.+)$/) {
        my $arg = $1;
        push @call_target, split /,/, $arg;
    } elsif (/^--as-root$/) {
        $call_target_as_root = 1;
    } elsif (/^--pre-clean$/) {
	$noclean = 0;
    } elsif (/^-nc$/ or /^--no-pre-clean$/) {
	$noclean = 1;
    } elsif (/^--build=(.*)$/) {
        set_build_type_from_options($1, $_);
    } elsif (/^-b$/) {
	set_build_type(BUILD_BINARY, $_);
    } elsif (/^-B$/) {
	set_build_type(BUILD_ARCH_DEP, $_);
    } elsif (/^-A$/) {
	set_build_type(BUILD_ARCH_INDEP, $_);
    } elsif (/^-S$/) {
	set_build_type(BUILD_SOURCE, $_);
    } elsif (/^-G$/) {
	set_build_type(BUILD_SOURCE | BUILD_ARCH_DEP, $_);
    } elsif (/^-g$/) {
	set_build_type(BUILD_SOURCE | BUILD_ARCH_INDEP, $_);
    } elsif (/^-F$/) {
	set_build_type(BUILD_FULL, $_);
    } elsif (/^-v(.*)$/) {
	$since = $1;
    } elsif (/^-m(.*)$/ or /^--release-by=(.*)$/) {
	$maint = $1;
    } elsif (/^-e(.*)$/ or /^--build-by=(.*)$/) {
	$changedby = $1;
    } elsif (/^-C(.*)$/) {
	$desc = $1;
    } elsif (m/^-[EW]$/) {
	# Deprecated option
	warning(g_('-E and -W are deprecated, they are without effect'));
    } elsif (/^-R(.*)$/ or /^--rules-target=(.*)$/) {
	my $arg = $1;
	@debian_rules = split /\s+/, $arg;
    } else {
	usageerr(g_('unknown option or argument %s'), $_);
    }
}

if (build_has_all(BUILD_BINARY)) {
    $buildtarget = 'build';
    $binarytarget = 'binary';
} elsif (build_has_any(BUILD_ARCH_DEP)) {
    $buildtarget = 'build-arch';
    $binarytarget = 'binary-arch';
} elsif (build_has_any(BUILD_ARCH_INDEP)) {
    $buildtarget = 'build-indep';
    $binarytarget = 'binary-indep';
}

if ($noclean) {
    # -nc without -b/-B/-A/-S/-F implies -b
    set_build_type(BUILD_BINARY) if build_has_any(BUILD_DEFAULT);
    # -nc with -S implies no dependency checks
    $checkbuilddep = 0 if build_is(BUILD_SOURCE);
}

if ($< == 0) {
    warning(g_('using a gain-root-command while being root')) if (@rootcommand);
} else {
    push @rootcommand, 'fakeroot' unless @rootcommand;
}

if (@rootcommand and not find_command($rootcommand[0])) {
    if ($rootcommand[0] eq 'fakeroot' and $< != 0) {
        error(g_("fakeroot not found, either install the fakeroot\n" .
                 'package, specify a command with the -r option, ' .
                 'or run this as root'));
    } else {
        error(g_("gain-root-commmand '%s' not found"), $rootcommand[0]);
    }
}

if ($check_command and not find_command($check_command)) {
    error(g_("check-commmand '%s' not found"), $check_command);
}

if ($signcommand) {
    if (!find_command($signcommand)) {
        error(g_("sign-commmand '%s' not found"), $signcommand);
    }
} elsif (($ENV{GNUPGHOME} && -e $ENV{GNUPGHOME}) ||
         ($ENV{HOME} && -e "$ENV{HOME}/.gnupg")) {
    if (find_command('gpg2')) {
        $signcommand = 'gpg2';
    } elsif (find_command('gpg')) {
        $signcommand = 'gpg';
    }
}

# Default to auto if none of parallel=N, -J or -j have been specified.
if (not defined $parallel and not $build_opts->has('parallel')) {
    $parallel = 'auto';
}

if (defined $parallel) {
    if ($parallel eq 'auto') {
        # Most Unices.
        $parallel = qx(getconf _NPROCESSORS_ONLN 2>/dev/null);
        # Fallback for at least Irix.
        $parallel = qx(getconf _NPROC_ONLN 2>/dev/null) if $?;
        # Fallback to serial execution if cannot infer the number of online
        # processors.
        $parallel = '1' if $?;
        chomp $parallel;
    }
    if ($parallel_force) {
        $ENV{MAKEFLAGS} //= '';
        $ENV{MAKEFLAGS} .= " -j$parallel";
    }
    $build_opts->set('parallel', $parallel);
    $build_opts->export();
}

set_build_profiles(@build_profiles) if @build_profiles;

my $cwd = cwd();
my $dir = basename($cwd);

my $changelog = changelog_parse();

my $pkg = mustsetvar($changelog->{source}, g_('source package'));
my $version = mustsetvar($changelog->{version}, g_('source version'));
my $v = Dpkg::Version->new($version);
my ($ok, $error) = version_check($v);
error($error) unless $ok;

my $sversion = $v->as_string(omit_epoch => 1);
my $uversion = $v->version();

my $distribution = mustsetvar($changelog->{distribution}, g_('source distribution'));

my $maintainer;
if ($changedby) {
    $maintainer = $changedby;
} elsif ($maint) {
    $maintainer = $maint;
} else {
    $maintainer = mustsetvar($changelog->{maintainer}, g_('source changed by'));
}

# <https://reproducible-builds.org/specs/source-date-epoch/>
$ENV{SOURCE_DATE_EPOCH} ||= $changelog->{timestamp} || time;

my @arch_opts;
push @arch_opts, ('--host-arch', $host_arch) if $host_arch;
push @arch_opts, ('--host-type', $host_type) if $host_type;
push @arch_opts, ('--target-arch', $target_arch) if $target_arch;
push @arch_opts, ('--target-type', $target_type) if $target_type;

open my $arch_env, '-|', 'dpkg-architecture', '-f', @arch_opts
    or subprocerr('dpkg-architecture');
while (<$arch_env>) {
    chomp;
    my ($key, $value) = split /=/, $_, 2;
    $ENV{$key} = $value;
}
close $arch_env or subprocerr('dpkg-architecture');

my $arch;
if (build_has_any(BUILD_ARCH_DEP)) {
    $arch = mustsetvar($ENV{DEB_HOST_ARCH}, g_('host architecture'));
} elsif (build_has_any(BUILD_ARCH_INDEP)) {
    $arch = 'all';
} elsif (build_has_any(BUILD_SOURCE)) {
    $arch = 'source';
}

my $pv = "${pkg}_$sversion";
my $pva = "${pkg}_${sversion}_$arch";

if (not $signcommand) {
    $signsource = 0;
    $signbuildinfo = 0;
    $signchanges = 0;
} elsif ($signforce) {
    $signsource = 1;
    $signbuildinfo = 1;
    $signchanges = 1;
} elsif (($signsource or $signbuildinfo or $signchanges) and
         $distribution eq 'UNRELEASED') {
    $signreleased = 0;
    $signsource = 0;
    $signbuildinfo = 0;
    $signchanges = 0;
}

if ($signsource && build_has_none(BUILD_SOURCE)) {
    $signsource = 0;
}

#
# Preparation of environment stops here
#

run_hook('init', 1);

if (not -x 'debian/rules') {
    warning(g_('debian/rules is not executable; fixing that'));
    chmod(0755, 'debian/rules'); # No checks of failures, non fatal
}

if (scalar @call_target == 0) {
    chdir('..') or syserr('chdir ..');
    withecho('dpkg-source', @source_opts, '--before-build', $dir);
    chdir($dir) or syserr("chdir $dir");
}

if ($checkbuilddep) {
    my @checkbuilddep_opts;

    push @checkbuilddep_opts, '-A' if build_has_none(BUILD_ARCH_DEP);
    push @checkbuilddep_opts, '-B' if build_has_none(BUILD_ARCH_INDEP);
    push @checkbuilddep_opts, '-I' if not $check_builtin_builddep;
    push @checkbuilddep_opts, "--admindir=$admindir" if $admindir;

    system('dpkg-checkbuilddeps', @checkbuilddep_opts);
    if (not WIFEXITED($?)) {
        subprocerr('dpkg-checkbuilddeps');
    } elsif (WEXITSTATUS($?)) {
	warning(g_('build dependencies/conflicts unsatisfied; aborting'));
	warning(g_('(Use -d flag to override.)'));
	exit 3;
    }
}

foreach my $call_target (@call_target) {
    if ($call_target_as_root or
        $call_target =~ /^(clean|binary(|-arch|-indep))$/)
    {
        withecho(@rootcommand, @debian_rules, $call_target);
    } else {
        withecho(@debian_rules, $call_target);
    }
}
exit 0 if scalar @call_target;

run_hook('preclean', ! $noclean);

unless ($noclean) {
    withecho(@rootcommand, @debian_rules, 'clean');
}

run_hook('source', build_has_any(BUILD_SOURCE));

if (build_has_any(BUILD_SOURCE)) {
    warning(g_('building a source package without cleaning up as you asked; ' .
               'it might contain undesired files')) if $noclean;
    chdir('..') or syserr('chdir ..');
    withecho('dpkg-source', @source_opts, '-b', $dir);
    chdir($dir) or syserr("chdir $dir");
}

run_hook('build', build_has_any(BUILD_BINARY));

# XXX Use some heuristics to decide whether to use build-{arch,indep} targets.
# This is a temporary measure to not break too many packages on a flag day.
build_target_fallback();

my $build_types = get_build_options_from_type();

if (build_has_any(BUILD_BINARY)) {
    withecho(@debian_rules, $buildtarget);
    run_hook('binary', 1);
    withecho(@rootcommand, @debian_rules, $binarytarget);
}

run_hook('buildinfo', 1);

push @buildinfo_opts, "--build=$build_types" if build_has_none(BUILD_DEFAULT);
push @buildinfo_opts, "--admindir=$admindir" if $admindir;

withecho('dpkg-genbuildinfo', @buildinfo_opts);

run_hook('changes', 1);

push @changes_opts, "--build=$build_types" if build_has_none(BUILD_DEFAULT);
push @changes_opts, "-m$maint" if defined $maint;
push @changes_opts, "-e$changedby" if defined $changedby;
push @changes_opts, "-v$since" if defined $since;
push @changes_opts, "-C$desc" if defined $desc;

my $chg = "../$pva.changes";
my $changes = Dpkg::Control->new(type => CTRL_FILE_CHANGES);

printcmd("dpkg-genchanges @changes_opts >$chg");

open my $changes_fh, '-|', 'dpkg-genchanges', @changes_opts
    or subprocerr('dpkg-genchanges');
$changes->parse($changes_fh, g_('parse changes file'));
$changes->save($chg);
close $changes_fh or subprocerr(g_('dpkg-genchanges'));

run_hook('postclean', $cleansource);

if ($cleansource) {
    withecho(@rootcommand, @debian_rules, 'clean');
}

chdir('..') or syserr('chdir ..');
withecho('dpkg-source', @source_opts, '--after-build', $dir);
chdir($dir) or syserr("chdir $dir");

info(describe_build($changes->{'Files'}));

run_hook('check', $check_command);

if ($check_command) {
    withecho($check_command, @check_opts, $chg);
}

if ($signpause && ($signsource || $signbuildinfo || $signchanges)) {
    print g_("Press <enter> to start the signing process.\n");
    getc();
}

run_hook('sign', $signsource || $signbuildinfo || $signchanges);

if ($signsource) {
    if (signfile("$pv.dsc")) {
        error(g_('failed to sign %s file'), '.dsc');
    }

    # Recompute the checksums as the .dsc have changed now.
    my $buildinfo = Dpkg::Control->new(type => CTRL_FILE_BUILDINFO);
    $buildinfo->load("../$pva.buildinfo");
    my $checksums = Dpkg::Checksums->new();
    $checksums->add_from_control($buildinfo);
    $checksums->add_from_file("../$pv.dsc", update => 1, key => "$pv.dsc");
    $checksums->export_to_control($buildinfo);
    $buildinfo->save("../$pva.buildinfo");
}
if ($signbuildinfo && signfile("$pva.buildinfo")) {
    error(g_('failed to sign %s file'), '.buildinfo');
}
if ($signsource or $signbuildinfo) {
    # Recompute the checksums as the .dsc and/or .buildinfo have changed.
    my $checksums = Dpkg::Checksums->new();
    $checksums->add_from_control($changes);
    $checksums->add_from_file("../$pv.dsc", update => 1, key => "$pv.dsc");
    $checksums->add_from_file("../$pva.buildinfo", update => 1, key => "$pva.buildinfo");
    $checksums->export_to_control($changes);
    delete $changes->{'Checksums-Md5'};
    update_files_field($changes, $checksums, "$pv.dsc");
    update_files_field($changes, $checksums, "$pva.buildinfo");
    $changes->save($chg);
}
if ($signchanges && signfile("$pva.changes")) {
    error(g_('failed to sign %s file'), '.changes');
}

if (not $signreleased) {
    warning(g_('not signing UNRELEASED build; use --force-sign to override'));
}

run_hook('done', 1);

sub mustsetvar {
    my ($var, $text) = @_;

    error(g_('unable to determine %s'), $text)
	unless defined($var);

    info("$text $var");
    return $var;
}

sub withecho {
    printcmd(@_);
    system(@_)
	and subprocerr("@_");
}

sub run_hook {
    my ($name, $enabled) = @_;
    my $cmd = $hook{$name};

    return if not $cmd;

    info("running hook $name");

    my %hook_vars = (
        '%' => '%',
        'a' => $enabled ? 1 : 0,
        'p' => $pkg,
        'v' => $version,
        's' => $sversion,
        'u' => $uversion,
    );

    my $subst_hook_var = sub {
        my $var = shift;

        if (exists $hook_vars{$var}) {
            return $hook_vars{$var};
        } else {
            warning(g_('unknown %% substitution in hook: %%%s'), $var);
            return "\%$var";
        }
    };

    $cmd =~ s/\%(.)/&$subst_hook_var($1)/eg;

    withecho($cmd);
}

sub update_files_field {
    my ($ctrl, $checksums, $filename) = @_;

    my $md5sum_regex = checksums_get_property('md5', 'regex');
    my $md5sum = $checksums->get_checksum($filename, 'md5');
    my $size = $checksums->get_size($filename);
    my $file_regex = qr/$md5sum_regex\s+\d+\s+(\S+\s+\S+\s+\Q$filename\E)/;

    $ctrl->{'Files'} =~ s/^$file_regex$/$md5sum $size $1/m;
}

sub signfile {
    my $file = shift;

    printcmd("signfile $file");

    my $signdir = tempdir('dpkg-sign.XXXXXXXX', CLEANUP => 1);
    my $signfile = "$signdir/$file";

    # Make sure the file to sign ends with a newline.
    copy("../$file", $signfile);
    open my $signfh, '>>', $signfile or syserr(g_('cannot open %s'), $signfile);
    print { $signfh } "\n";
    close $signfh or syserr(g_('cannot close %s'), $signfile);

    system($signcommand, '--utf8-strings', '--textmode', '--armor',
           '--local-user', $signkey || $maintainer, '--clearsign',
           '--output', "$signfile.asc", $signfile);
    my $status = $?;
    if ($status == 0) {
	system('mv', '--', "$signfile.asc", "../$file")
	    and subprocerr('mv');
    }

    print "\n";
    return $status
}

sub fileomitted {
    my ($files, $regex) = @_;

    return $files !~ /$regex/
}

sub describe_build {
    my $files = shift;
    my $ext = compression_get_file_extension_regex();

    if (fileomitted($files, qr/\.deb/)) {
        # source-only upload
        if (fileomitted($files, qr/\.diff\.$ext/) and
            fileomitted($files, qr/\.debian\.tar\.$ext/)) {
            return g_('source-only upload: Debian-native package');
        } elsif (fileomitted($files, qr/\.orig\.tar\.$ext/)) {
            return g_('source-only, diff-only upload (original source NOT included)');
        } else {
            return g_('source-only upload (original source is included)');
        }
    } elsif (fileomitted($files, qr/\.dsc/)) {
        return g_('binary-only upload (no source included)');
    } elsif (fileomitted($files, qr/\.diff\.$ext/) and
             fileomitted($files, qr/\.debian\.tar\.$ext/)) {
        return g_('full upload; Debian-native package (full source is included)');
    } elsif (fileomitted($files, qr/\.orig\.tar\.$ext/)) {
        return g_('binary and diff upload (original source NOT included)');
    } else {
        return g_('full upload (original source is included)');
    }
}

sub build_target_fallback {
    return if $buildtarget eq 'build';
    return if scalar @debian_rules != 1;

    # Check if we are building both arch:all and arch:any packages, in which
    # case we now require working build-indep and build-arch targets.
    my $pkg_arch = 0;
    my $ctrl = Dpkg::Control::Info->new();

    foreach my $bin ($ctrl->get_packages()) {
        if ($bin->{Architecture} eq 'all') {
            $pkg_arch |= BUILD_ARCH_INDEP;
        } else {
            $pkg_arch |= BUILD_ARCH_DEP;
        }
    }

    return if $pkg_arch == BUILD_BINARY;

    # Check if the build-{arch,indep} targets are supported. If not, fallback
    # to build.
    my $pid = spawn(exec => [ $Dpkg::PROGMAKE, '-f', @debian_rules, '-qn', $buildtarget ],
                    from_file => '/dev/null', to_file => '/dev/null',
                    error_to_file => '/dev/null');
    my $cmdline = "make -f @debian_rules -qn $buildtarget";
    wait_child($pid, nocheck => 1, cmdline => $cmdline);
    my $exitcode = WEXITSTATUS($?);
    subprocerr($cmdline) unless WIFEXITED($?);
    if ($exitcode == 2) {
        warning(g_("%s must be updated to support the 'build-arch' and " .
                   "'build-indep' targets (at least '%s' seems to be " .
                   'missing)'), "@debian_rules", $buildtarget);
        $buildtarget = 'build';
    }
}
