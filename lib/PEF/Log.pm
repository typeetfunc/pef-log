package PEF::Log;
use strict;
use warnings;
use Carp;
use Time::HiRes qw(time);
use PEF::Log::Config;
use Scalar::Util qw(weaken blessed reftype);
use base 'Exporter';
use feature 'state';

our $VERSION = '0.01';

our @EXPORT = qw{
  logcache
  logcontext
  logit
  logstore
};

our $start_time;
our $last_log_event;
our $caller_offset;
our @context;
our @context_stash;
our %stash;

BEGIN {
	$start_time     = time;
	$last_log_event = 0;
	@context        = (\"main");
	@context_stash  = ({});
	$caller_offset  = 0;
}

sub import {
	my ($class, @args) = @_;
	my ($sln, $sublevels);
	for (my $i = 0 ; $i < @args ; ++$i) {
		if ($args[$i] eq 'sublevels') {
			($sln, $sublevels) = splice @args, $i, 2;
			--$i;
			$sublevels = [$sublevels] if 'ARRAY' ne ref $sublevels;
		}
	}
	require PEF::Log::Levels;
	my @slim = $sln ? ($sln, $sublevels) : ();
	PEF::Log::Levels->import(@slim);
	my %imps = map { $_ => undef } @args, @EXPORT;
	$class->export_to_level(1, $class, keys %imps);

}

sub init {
	shift @_ if $_[0] eq __PACKAGE__;
	PEF::Log::Config::init(@_);
}

sub reload {
	shift @_ if $_[0] eq __PACKAGE__;
	PEF::Log::Config::reload(@_);
}

sub get_appender ($) {
	my $ap = $_[0];
	return if not exists $PEF::Log::Config::config{appenders}{$ap};
	$PEF::Log::Config::config{appenders}{$ap};
}

sub logstore {
	if (@_ == 1) {
		$stash{$_[0]};
	} elsif (@_ == 0) {
		\%stash;
	} else {
		$stash{$_[0]} = $_[1];
	}
}

sub _clean_context {
	pop @context while @context and not defined $context[-1];
	splice @context_stash, scalar @context;
}

sub logcache {
	_clean_context;
	my $cache = $context_stash[-1];
	if (@_ == 1) {
		$cache->{$_[0]};
	} elsif (@_ == 0) {
		$cache;
	} else {
		$cache->{$_[0]} = $_[1];
	}
}

sub logcontext {
	_clean_context;
	if (@_) {
		carp "not scalar reference" if 'SCALAR' ne ref $_[0];
		push @context, $_[0];
		weaken($context[-1]);
		push @context_stash, {};
		return ${$context[-1]} if defined wantarray;
	} else {
		${$context[-1]};
	}
}

sub popcontext ($) {
	_clean_context;
	for (my $i = @context - 1 ; $i > 0 ; --$i) {
		if (${$context[$i]} eq $_[0]) {
			splice @context,       $i;
			splice @context_stash, $i;
			last;
		}
	}
}

sub _route {
	my ($level, $sublevel) = @_;
	my $routes = $PEF::Log::Config::config{routes};
	my $context;
	my $subroutine;
	my @scd;
	if (exists ($routes->{subroutine}) && 'HASH' eq ref ($routes->{subroutine}) && %{$routes->{subroutine}}) {
		my $ssn;
		for (my $stlvl = 1 ; ; ++$stlvl) {
			my @caller = caller ($PEF::Log::caller_offset + $stlvl);
			$subroutine = $caller[3];
			last if not defined $subroutine;
			($ssn = $subroutine) =~ s/.*:://;
			last if $ssn ne '(eval)' and $ssn ne '__ANON__';
		}
		if (defined $subroutine) {
			if (not exists $routes->{subroutine}{$subroutine}) {
				if (exists $routes->{subroutine}{$ssn}) {
					$subroutine = $ssn;
				} else {
					$subroutine = undef;
				}
			}
		}
		push @scd, $routes->{subroutine}{$subroutine} if $subroutine;
	}
	if (exists ($routes->{context}) && 'HASH' eq ref ($routes->{context}) && %{$routes->{context}}) {
		$context = logcontext();
		$context = undef unless exists $routes->{context}{$context};
		push @scd, $routes->{context}{$context} if $context;
	}
	if (exists ($routes->{package}) && 'HASH' eq ref ($routes->{package}) && %{$routes->{package}}) {
		my $package = caller (1);
		if (not exists $routes->{package}{$package}) {
			$package = undef;
		}
		push @scd, $routes->{package}{$package} if $package;
	}
	push @scd, $routes->{default} if exists $routes->{default};
	my $opts;
	my $apnd      = [];
	my $check_lvl = sub {
		my $lvl = $_[0];
		if (not exists $opts->{$lvl}) {
			if (exists $opts->{default}) {
				$lvl = 'default';
			} else {
				return;
			}
		}
		if (not ref $opts->{$lvl}) {
			if ($opts->{$lvl} eq 'off') {
				$opts = undef;
			} else {
				$apnd = [$opts->{$lvl}];
			}
		} elsif ('ARRAY' eq ref $opts->{$lvl}) {
			$apnd = $opts->{$lvl};
		} else {
			$opts = $opts->{$lvl};
			return 1;
		}
		return;
	};
	my @larr = ($level);
	push @larr, $sublevel if $sublevel;
	for my $ft (@scd) {
		$opts = $ft;
		for my $l (@larr) {
			last if not $check_lvl->($l);
		}
		last if not $opts or @$apnd;
	}
	$apnd;
}

sub logit {
	state $lvl_prefix = "PEF::Log::Levels::";
	for (my $imsg = 0 ; $imsg < @_ ; ++$imsg) {
		my $msg = $_[$imsg];
		my $blt = blessed $msg;
		if (not $blt) {
			$msg = PEF::Log::Levels::warning { {"not blessed message" => $msg} };
			$blt = blessed $msg;
		}
		if (substr ($blt, 0, length $lvl_prefix) ne $lvl_prefix) {
			$msg = PEF::Log::Levels::warning { {"unknown msg level" => $blt, message => $msg} };
			$blt = blessed $msg;
		}
		my ($level, $sublevel) = split /::/, substr ($blt, length $lvl_prefix);
		my $appenders = _route($level, $sublevel);
		return if !@$appenders;
		my @mval = $msg->();
		for my $omv (@mval) {
			for my $ap (@$appenders) {
				if (not exists $PEF::Log::Config::config{appenders}{$ap}) {
					push @_, PEF::Log::Levels::error { {"unknown appender" => $ap} };
				} else {
					$PEF::Log::Config::config{appenders}{$ap}->append($level, $sublevel, $omv);
				}
			}
		}
	}
}

1;
