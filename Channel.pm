# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Channel; {
use Object::InsideOut;
use Nick;
use strict;
use warnings;

=head1 Channel

Object representing a set of linked channels

=over

=cut

my @ts :Field :Get(ts);
my @keyname :Field :Get(keyname);
my @topic :Field :Arg(topic);
my @topicts :Field;
my @topicset :Field :Arg(topicset);
my @mode :Field;

my @names :Field;
my @nets :Field;

my @nicks :Field;
my @nmode :Field;

=item $chan->nets()

List of all networks this channel is on

=cut

sub nets {
	values %{$nets[${$_[0]}]};
}

=item $chan->has_nmode($mode, $nick)

Returns true if the nick has the given mode in the channel (n_* modes)

=cut

sub has_nmode {
	my($chan, $mode, $nick) = @_;
	$nmode[$$chan]{$nick->lid()}{$mode};
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
# perl -e "print q[\$out .= ' ],\$_,q[='.\$ij->ijstr(\$],\$_,q[{\$\$chan});],qq(\n) for qw/keyname ts topic topicts topicset mode names/"
	$out .= ' keyname='.$ij->ijstr($keyname[$$chan]);
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' names='.$ij->ijstr($names[$$chan]);
	$out;
}

my %initargs :InitArgs = (
	keyname => '',
	names => '',
	net => '',
	name => '',
	ts => '',
	topicts => '',
	mode => '',
);

sub _init :Init {
	my($c, $ifo) = @_;
	$topicts[$$c] = $ifo->{topicts} || 0;
	$mode[$$c] = $ifo->{mode} || {};
	if ($ifo->{keyname}) {
		$keyname[$$c] = $ifo->{keyname};
		my $names = $ifo->{names} || {};
		$names[$$c] = $names;
		for my $id (keys %$names) {
			my $name = $names->{$id};
			$nets[$$c]{$id} = $Janus::nets{$id};
			$Janus::gchans{$id.$name} = $c;
		}
		$ts[$$c] = $ifo->{ts} || (time + 60);
	} else {
		my $net = $ifo->{net};
		my $id = $net->id();
		$keyname[$$c] = $id.$ifo->{name};
		$nets[$$c]{$id} = $net;
		$names[$$c]{$id} = $ifo->{name};
		$Janus::gchans{$id.$ifo->{name}} = $c;
		$ts[$$c] = $ifo->{ts} || (time + 60);
	}
}

sub _destroy :Destroy {
	my $c = $_[0];
	my $n = join ',', map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
	print "   CHAN: $n deallocated\n";
}

sub _mergenet {
	my($chan, $src) = @_;
	for my $id (keys %{$nets[$$src]}) {
		$nets[$$chan]{$id}  = $nets[$$src]{$id};
		$names[$$chan]{$id} = $names[$$src]{$id};
	}
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$mode[$$src]}) {
		if ($txt =~ /^l/) {
			$mode[$$chan]{$txt} = [ @{$mode[$$src]{$txt}} ];
		} else {
			$mode[$$chan]{$txt} = $mode[$$src]{$txt};
		}
	}
}

sub _mode_delta {
	my($chan, $dst) = @_;
	my %add = %{$mode[$$dst]};
	my(@modes, @args);
	for my $txt (keys %{$mode[$$chan]}) {
		if ($txt =~ /^l/) {
			my %torm = map { $_ => 1} @{$mode[$$chan]{$txt}};
			if (exists $add{$txt}) {
				for my $i (@{$add{$txt}}) {
					if (exists $torm{$i}) {
						delete $torm{$i};
					} else {
						push @modes, '+'.$txt;
						push @args, $i;
					}
				}
			}
			for my $i (keys %torm) {
				push @modes, '-'.$txt;
				push @args, $i;
			}
		} elsif ($txt =~ /^[vs]/) {
			if (exists $add{$txt}) {
				if ($mode[$$chan]{$txt} eq $add{$txt}) {
					# hey, isn't that nice
				} else {
					push @modes, '+'.$txt;
					push @args, $add{$txt};
				}
			} else {
				push @modes, '-'.$txt;
				push @args, $mode[$$chan]{$txt} unless $txt =~ /^s/;
			}
		} else {
			push @modes, '-'.$txt unless exists $add{$txt};
		}
		delete $add{$txt};
	}
	for my $txt (keys %add) {
		if ($txt =~ /^l/) {
			for my $i (@{$add{$txt}}) {
				push @modes, '+'.$txt;
				push @args, $i;
			}
		} elsif ($txt =~ /^[vs]/) {
			push @modes, '+'.$txt;
			push @args, $add{$txt};
		} else {
			push @modes, '+'.$txt;
		}
	}
	(\@modes, \@args);
}

sub _link_into {
	my($src,$chan) = @_;
	for my $id (keys %{$nets[$$src]}) {
		my $net = $nets[$$src]{$id};
		my $name = $names[$$src]{$id};
		$Janus::gchans{$id.$name} = $chan;
		next if $net->jlink();
		$net->replace_chan($name, $chan);
	}

	for my $nid (keys %{$nicks[$$src]}) {
		my $nick = $nicks[$$src]{$nid};
		$nicks[$$chan]{$nid} = $nick;

		my $mode = $nmode[$$src]{$nid};
		$nmode[$$chan]{$nid} = $mode;

		$nick->rejoin($chan);
		&Janus::append(+{
			type => 'JOIN',
			src => $nick,
			dst => $chan,
			mode => $nmode[$$src]{$nid},
			rejoin => 1,
		}) unless $nick->jlink();
	}

	if (($topic[$$src] || '') ne ($topic[$$chan] || '')) {
		&Janus::append(+{
			type => 'TOPIC',
			dst => $src,
			topic => $topic[$$chan],
			topicts => $topicts[$$chan],
			topicset => $topicset[$$chan],
			nojlink => 1,
		});
	}

	my ($mode, $marg) = $src->_mode_delta($chan);
	&Janus::append(+{
		type => 'MODE',
		dst => $src,
		mode => $mode,
		args => $marg,
		nojlink => 1,
	}) if @$mode;
}

=item $chan->str($net)

get the channel's name on a given network, or undef if the channel is
not on the network

=cut

sub str {
	my($chan,$net) = @_;
	$names[$$chan]{$net->id()};
}

=item $chan->is_on($net)

returns true if the channel is linked onto the given network

=cut

sub is_on {
	my($chan, $net) = @_;
	exists $nets[$$chan]{$net->id()};
}

sub sendto {
	my($chan,$act,$except) = @_;
	my %n = %{$nets[$$chan]};
	delete $n{$except->id()} if $except;
	values %n;
}

=item $chan->part($nick)

remove records of this nick (for quitting nicks)

=cut

sub part {
	my($chan,$nick) = @_;
	delete $nicks[$$chan]{$nick->lid()};
	delete $nmode[$$chan]{$nick->lid()};
	return if keys %{$nicks[$$chan]};
	# destroy channel
	for my $id (keys %{$nets[$$chan]}) {
		my $net = $nets[$$chan]{$id};
		my $name = $names[$$chan]{$id};
		delete $Janus::gchans{$id.$name};
		next if $net->jlink();
		$net->replace_chan($name, undef);
	}
}

=item $chan->timesync($newts)

If the new timestamp is lower than the current one, wipe modes on the channel
and set the new timestmp

=cut

# TODO send the new timestamp and/or mode wipe across IJ link
sub timesync {
	my($chan, $new) = @_;
	unless ($new > 1000000) {
		#don't EVER destroy channel TSes with that annoying Unreal message
		warn "Not destroying channel timestamp; mode desync may happen!" if $new;
		return;
	}
	my $old = $ts[$$chan];
	return if $old <= $new; # we are actually not resetting the TS, how nice!
	# Wipe modes in preparation for an overriding merge
	$ts[$$chan] = $new;
	$nmode[$$chan] = {};
	$mode[$$chan] = {};
}

sub modload {
 my $me = shift;
 &Janus::hook_add($me,
 	JOIN => validate => sub {
		my $act = $_[0];
		my $valid = eval {
			return 0 unless $act->{src}->isa('Nick');
			return 0 unless $act->{dst}->isa('Channel');
			1;
		};
		$valid ? undef : 1;
	}, JOIN => act => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$nicks[$$chan]{$nick->lid()} = $nick;
		if ($act->{mode}) {
			$nmode[$$chan]{$nick->lid()} = { %{$act->{mode}} };
		}
	}, PART => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$chan->part($nick);
	}, KICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};
		$chan->part($nick);
	}, MODE => act => sub {
		my $act = $_[0];
		local $_;
		my $chan = $act->{dst};
		my @args = @{$act->{args}};
		for my $itxt (@{$act->{mode}}) {
			my $pm = substr $itxt, 0, 1;
			my $t = substr $itxt, 1, 1;
			my $i = substr $itxt, 1;
			if ($t eq 'n') {
				my $nick = shift @args or next;
				$nmode[$$chan]{$nick->lid()}{$i} = 1 if $pm eq '+';
				delete $nmode[$$chan]{$nick->lid()}{$i} if $pm eq '-';
			} elsif ($t eq 'l') {
				if ($pm eq '+') {
					push @{$mode[$$chan]{$i}}, shift @args;
				} else {
					my $b = shift @args;
					@{$mode[$$chan]{$i}} = grep { $_ ne $b } @{$mode[$$chan]{$i}};
				}
			} elsif ($t eq 'v') {
				$mode[$$chan]{$i} = shift @args;
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 's') {
				$mode[$$chan]{$i} = shift @args if $pm eq '+';
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 'r') {
				$mode[$$chan]{$i} = 1;
				delete $mode[$$chan]{$i} if $pm eq '-';
			} else {
				warn "Unknown mode '$itxt'";
			}
		}
	}, TOPIC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		$topic[$$chan] = $act->{topic};
		$topicts[$$chan] = $act->{topicts} || time;
		$topicset[$$chan] = $act->{topicset} || $act->{src}->homenick();
	}, LSYNC => act => sub {
		my $act = shift;
		return if $act->{dst}->jlink();
		my $chan1 = $act->{dst}->chan($act->{linkto},1);
		my $chan2 = $act->{chan};
	
		# This is the atomic creation of the merged channel. Everyone else
		# just gets a copy of the channel created here and send out the 
		# events required to merge into it.

		for my $id (keys %{$nets[$$chan1]}) {
			if (exists $nets[$$chan2]{$id}) {
				Janus::jmsg($act->{src}, "Cannot link: this channel would be in $id twice");
				return;
			}
		}
	
		my $chan = Channel->new(keyname => $keyname[$$chan1], names => {});

		my $tsctl = ($ts[$$chan2] <=> $ts[$$chan1]);
		# topic timestamps are backwards: later topic change is taken IF the creation stamps are the same
		# otherwise go along with the channel sync

		# basic strategy: Modify the two channels in-place to have the same modes as we create
		# the unified channel

		# First, set the timestamps
		$chan1->timesync($ts[$$chan2]);
		$chan2->timesync($ts[$$chan1]);
		$ts[$$chan] = $ts[$$chan1]; # the timestamps are now equal so just copy #1 because it's first

		my $topctl = ($tsctl > 0 || ($tsctl == 0 && $topicts[$$chan1] >= $topicts[$$chan2]))
			? $$chan1 : $$chan2;
		$topic[$$chan] = $topic[$topctl];
		$topicts[$$chan] = $topicts[$topctl];
		$topicset[$$chan] = $topicset[$topctl];

		if ($tsctl > 0) {
			print "Channel 1 wins TS\n";
			$chan->_modecpy($chan1);
		} elsif ($tsctl < 0) {
			print "Channel 2 wins TS\n";
			$chan->_modecpy($chan2);
		} else {
			# Equal timestamps; recovering from a split. Merge any information
			my @allmodes = keys(%{$mode[$$chan1]}), keys(%{$mode[$$chan2]});
			for my $txt (@allmodes) {
				if ($txt =~ /^l/) {
					my %m;
					if (exists $mode[$$chan1]{$txt}) {
						$m{$_} = 1 for @{$mode[$$chan1]{$txt}};
					}
					if (exists $mode[$$chan2]{$txt}) {
						$m{$_} = 1 for @{$mode[$$chan2]{$txt}};
					}
					$mode[$$chan]{$txt} = [ keys %m ];
				} else {
					if (exists $mode[$$chan1]) {
						$mode[$$chan]{$txt} = $mode[$$chan1]{$txt};
					} else {
						$mode[$$chan]{$txt} = $mode[$$chan2]{$txt};
					}
				}
			}
		}

		$chan->_mergenet($chan1);
		$chan->_mergenet($chan2);

		&Janus::append(+{
			type => 'LINK',
			src => $act->{src},
			dst => $chan,
			chan1 => $chan1,
			chan2 => $chan2,
		});
	}, LINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my($chan1,$chan2) = ($act->{chan1}, $act->{chan2});
		
		$chan1->_link_into($chan) if $chan1;
		$chan2->_link_into($chan) if $chan2;
	}, DELINK => check => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		return 1 unless exists $nets[$$chan]{$net->id()};
		my @nets = keys %{$nets[$$chan]};
		return 1 if @nets == 1;
		undef;
	}, DELINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		my $id = $net->id();
		$act->{sendto} = [ values %{$nets[$$chan]} ]; # before the splitting
		delete $nets[$$chan]{$id} or warn;

		my $name = delete $names[$$chan]{$id};
		if ($keyname[$$chan] eq $id.$name) {
			my @onets = sort keys %{$names[$$chan]};
			$keyname[$$chan] = $onets[0].$names[$$chan]{$onets[0]};
		}
		my $split = Channel->new(
			net => $net,
			name => $name,
			ts => $ts[$$chan],
		);
		$topic[$$split] = $topic[$$chan];
		$topicts[$$split] = $topicts[$$chan];
		$topicset[$$split] = $topicset[$$chan];

		$act->{split} = $split;
		$split->_modecpy($chan);
		$net->replace_chan($name, $split);

		for my $nid (keys %{$nicks[$$chan]}) {
			if ($nicks[$$chan]{$nid}->homenet()->id() eq $id) {
				my $nick = $nicks[$$split]{$nid} = $nicks[$$chan]{$nid};
				$nmode[$$split]{$nid} = $nmode[$$chan]{$nid};
				$nick->rejoin($split);
				&Janus::append(+{
					type => 'PART',
					src => $nick,
					dst => $chan,
					msg => 'Channel delinked',
					nojlink => 1,
				});
			} else {
				my $nick = $nicks[$$split]{$nid} = $nicks[$$chan]{$nid};
				# need to insert the nick into the split off channel before the delink
				# PART is sent, because code is allowed to assume a PARTed nick was actually
				# in the channel it is parting from; this also keeps the channel from being 
				# prematurely removed from the list.
				&Janus::append(+{
					type => 'PART',
					src => $nick,
					dst => $split,
					sendto => [ $net ],
					msg => 'Channel delinked',
					nojlink => 1,
				});
			}
		}
	});
}

=back

=cut

} 1;
