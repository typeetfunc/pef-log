package PEF::Log::Format::FluentdJ;
use base 'PEF::Log::Format::Json';
use PEF::Log::Format::Pattern;
use PEF::Log::Stringify::DumpAll;
use JSON;
use Time::HiRes qw(time);
use Scalar::Util qw(blessed);
use Carp;
use strict;
use warnings;
use feature 'state';

sub formatter {
	my ($class, $params) = @_;
	my $container;
	my $formatter;
	if ($params->{container}) {
		$container = $params->{container};
	} elsif ($params->{format}) {
		$formatter = PEF::Log::Format::Pattern->formatter({format => $params->{format}});
	} else {
		$formatter = sub {
			my ($level, $stream, $message) = @_;
			if ('HASH' eq ref $message) {
				$message;
			} else {
				"[$level]: $message";
			}
		};
	}
	my $tag_format = $params->{tag} || "%l";
	my $tag;
	my $value_dumper = PEF::Log::Stringify::DumpAll->new(1);
	if (index ($tag_format, '%') != -1) {
		$tag = PEF::Log::Format::Pattern->formatter({format => $tag_format});
	} else {
		$tag = sub { $params->{tag} };
	}
	my $message_key = $params->{message_key} || 'message';
	state $prefix = "PEF::Log::Format::Flags::";
	return bless sub {
		my ($level, $stream, $message) = @_;
		my $msg;
		my $json_encoded;
		if ($formatter) {
			$msg = $formatter->($level, $stream, $message);
			$json_encoded = 0;
		} else {
			no warnings 'once';
			my $container_formatter = $PEF::Log::Config::config{formats}{$container};
			if (!$container_formatter) {
				$message = "misconfigured container: $container";
				$container_formatter = sub { $_[2] };
				carp "misconfigured container: $container";
			}
			my $bf = blessed($container_formatter);
			if ($bf && substr ($bf, 0, length $prefix) eq $prefix) {
				my @flags = split /:/, substr ($bf, length $prefix);
				$json_encoded = (grep { $_ eq 'JSON' } @flags) ? 1 : 0;
			}
			$msg = $container_formatter->($level, $stream, $message);
		}
		my $tag = $tag->($level, $stream, $message);
		my $ret;
		if ($json_encoded) {
			$ret = qq{["$tag", } . time . ", $msg]";
		} elsif('HASH' eq ref $msg) {
			$ret = encode_json [$tag, time, $msg];
		} else {
			$msg =~ s/\n$//s;
			$ret = encode_json [$tag, time, {$message_key => $msg, level => $level}];
		}
		$ret . "\n";
	}, "PEF::Log::Format::Flags::JSON:Fluentd";
}

1;
