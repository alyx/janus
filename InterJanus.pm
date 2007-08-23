# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package InterJanus;
use Persist;
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;
BEGIN {
	&Janus::load('Nick');
	&Janus::load('RemoteNetwork');
}

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @sendq :Persist('sendq');
my @id    :Persist('id')    :Arg(id) :Get(id);
my @auth  :Persist('auth');
my @pong  :Persist('ponged');

sub pongcheck {
	my $p = shift;
	my $ij = $p->{ij};
	if ($ij && !isweak($p->{ij})) {
		warn "Reference is strong! Weakening";
		weaken($p->{ij});
	}
	unless ($ij && defined $id[$$ij]) {
		delete $p->{repeat};
		&Conffile::connect_net(undef, $p->{id});
		return;
	}
	unless ($Janus::ijnets{$id[$$ij]} eq $ij) {
		delete $p->{repeat};
		warn "Network $ij not deallocated quickly enough!";
		return;
	}
	my $last = $pong[$$ij];
	if ($last + 90 <= time) {
		print "PING TIMEOUT!\n";
		&Janus::delink($ij, 'Ping timeout');
		&Conffile::connect_net(undef, $p->{id});
		delete $p->{ij};
		delete $p->{repeat};
	} elsif ($last + 29 <= time) {
		$ij->ij_send({ type => 'PING', sendto => [] });
	}
}

my %fromirc;
my %toirc;

my $INST_DBG = do {
	my $no;
	bless \$no;
};

sub str {
	warn;
	"";
}

sub intro {
	my($ij,$nconf) = @_;
	$sendq[$$ij] = '';

	$pong[$$ij] = time;
	my $pinger = {
		repeat => 30,
		ij => $ij,
		id => $nconf->{id},
		code => \&pongcheck,
	};
	weaken($pinger->{ij});
	&Janus::schedule($pinger);

	$Janus::ijnets{$id[$$ij]} = $ij;

	$ij->ij_send(+{
		type => 'InterJanus',
		version => 1,
		id => $nconf->{id},
		pass => $nconf->{sendpass},
	});
	for my $net (values %Janus::nets) {
		$ij->ij_send(+{
			type => 'NETLINK',
			net => $net,
		});
	}
}

sub jlink {
	$_[0];
}

my %esc2char = (
	e => '\\',
	g => '>',
	l => '<',
	n => "\n",
	q => '"',
);
my %char2esc; $char2esc{$esc2char{$_}} = $_ for keys %esc2char;

sub ijstr {
	my($ij, $itm) = @_;
	local $_;
	if (!defined $itm) {
		return '';
	} elsif (!ref $itm) {
		my $ch = join '', map { /\w/ ? $_ : '\\'.$_ } keys %char2esc;
		$itm =~ s/([$ch])/\\$char2esc{$1}/g;
		return '"'.$itm.'"';
	} elsif ('ARRAY' eq ref $itm) {
		my $out = '<a';
		$out .= ' '.$ij->ijstr($_) for @$itm;
		return $out.'>';
	} elsif ('HASH' eq ref $itm) {
		my $out = '<h';
		$out .= ' '.$_.'='.$ij->ijstr($itm->{$_}) for sort keys %$itm;
		return $out.'>';
	} elsif ($itm->isa('Nick')) {
		return 'n:'.$itm->gid();
	} elsif ($itm->isa('Channel')) {
		return 'c:'.$itm->keyname();
	} elsif ($itm->isa('Network')) {
		return 's:'.$itm->id();
	} elsif ($itm->isa('InterJanus')) {
		return '';
	}
	warn "Unknown object $itm";
	return '""';
}

sub send_hdr {
	my($ij, $act, @keys) = (@_,'sendto');
	my $out = "<$act->{type}";
	for my $key (@keys) {
		next unless exists $act->{$key};
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key}) 
	}
	$out;
}

sub ssend {
	my($ij, $act) = @_;
	my $out = "<$act->{type}";
	for my $key (sort keys %$act) {
		next if $key eq 'type' || $key eq 'except';
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key}) 
	}
	$out.'>';
}

sub ignore { (); }

my %to_ij = (
	NETLINK => sub {
		my($ij, $act) = @_;
		return '' if $act->{net}->isa('Interface');
		my $out = send_hdr(@_, qw/sendto/) . ' net=<s';
		$out .= $act->{net}->to_ij($ij);
		$out . '>>';
	}, LSYNC => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/dst linkto/) . ' chan=<c';
		$out .= $act->{chan}->to_ij($ij);
		$out . '>>';
	}, LINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/chan1 chan2/) . ' dst=<c';
		$out .= $act->{dst}->to_ij($ij);
		$out . '>>';
	}, CONNECT => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/net/) . ' dst=<n';
		$out .= $act->{dst}->to_ij($ij);
		$out . '>>';
	}, NICK => sub {
		send_hdr(@_,qw/dst nick/) . '>';
	},
	InterJanus => \&ssend,
	QUIT => \&ssend,
	KILL => \&ssend,
	NICKINFO => \&ssend,
	UMODE => \&ssend,
	MODE => \&ssend,
	TIMESYNC => \&ssend,
	JOIN => \&ssend,
	PART => \&ssend,
	KICK => \&ssend,
	TOPIC => \&ssend,
	MSG => \&ssend,
	WHOIS => \&ssend,
	CHATOPS => \&ssend,
	LINKREQ => \&ssend,
	DELINK => \&ssend,
	LINKED => \&ssend,
	NETSPLIT => \&ssend,
	PING => \&ssend,
	PONG => \&ssend,
);

sub debug_send {
	my $ij = $INST_DBG;
	for my $act (@_) {
		my $type = $act->{type};
		print "\e[0;33m    ACTION ";
		if (exists $to_ij{$type}) {
			print $to_ij{$type}->($ij, $act);
		} else {
			print ssend($ij, $act);
		}
		print "\e[0m\n";
	}
}

sub ij_send {
	my $ij = shift;
	my @out;
	for my $act (@_) {
		my $type = $act->{type};
		if (exists $to_ij{$type}) {
			push @out, $to_ij{$type}->($ij, $act);
		} else {
			print "Unknown action type '$type'\n";
		}
	}
	@out = grep $_, @out; #remove blank lines
	print "    OUT\@$id[$$ij]  $_\n" for @out;
	$sendq[$$ij] .= join '', map "$_\n", @out;
}

sub dump_sendq {
	my $ij = shift;
	my $q = $sendq[$$ij];
	$sendq[$$ij] = '';
	$q;
}

sub parse {
	my $ij = shift;
	$pong[$$ij] = time;
	local $_ = $_[0];
	print "     IN\@$id[$$ij]  $_\n";

	s/^\s*<(\S+)// or do {
		warn "bad line: $_";
		return ();
	};
	my $act = { type => $1 };
	$ij->_kv_pairs($act);
	warn "bad line: $_[0]" unless /^\s*>\s*$/;
	$act->{except} = $ij;
	if ($act->{type} eq 'PING') {
		$ij->ij_send({ type => 'PONG', sendto => [] });
	} elsif ($auth[$$ij]) {
		return $act;
	} elsif ($act->{type} eq 'InterJanus') {
		print "Unsupported InterJanus version $act->{version}\n" if $act->{version} ne '1';
		if ($id[$$ij] && $act->{id} ne $id[$$ij]) {
			print "Unexpected ID reply $act->{id} from IJ $id[$$ij]\n"
		} else {
			$id[$$ij] = $act->{id};
		}
		my $id = $id[$$ij];
		my $nconf = $Conffile::netconf{$id};
		if (!$nconf) {
			print "Unknown InterJanus server $id\n";
		} elsif ($act->{pass} ne $nconf->{recvpass}) {
			print "Failed authorization\n";
		} else {
			$auth[$$ij] = 1;
			$act->{net} = $ij;
			$act->{sendto} = [];
			return $act;
		}
		delete $Janus::ijnets{$id};
		delete $Janus::netqueues{$id};
	}
	return ();
}

my %v_type; %v_type = (
	' ' => sub {
		undef;
	}, '>' => sub {
		undef;
	}, '"' => sub {
		s/^"([^"]*)"//;
		my $v = $1;
		$v =~ s/\\(.)/$esc2char{$1}/g;
		$v;
	}, 'n' => sub {
		my $ij = shift;
		s/^n:([^ >]+)// or return undef;
		$Janus::gnicks{$1};
	}, 'c' => sub {
		my $ij = shift;
		s/^c:([^ >]+)// or return undef;
		$Janus::gchans{$1};
	}, 's' => sub {
		my $ij = shift;
		s/^s:([^ >]+)// or return undef;
		$Janus::nets{$1};
	}, '<a' => sub {
		my @arr;
		s/^<a// or warn;
		while (s/^\s+//) {
			my $v_t = substr $_,0,1;
			$v_t = substr $_,0,2 if $v_t eq '<';
			push @arr, $v_type{$v_t}->(@_);
		}
		s/^>// or warn;
		\@arr;
	}, '<h' => sub {
		my $ij = shift;
		my $h = {};
		s/^<h// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		$h;
	}, '<s' => sub {
		my $ij = shift;
		my $h = {};
		s/^<s// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		if ($Janus::nets{$h->{id}}) {
			# this is a NETLINK of a network we already know about.
			# We either have a loop or a name collision. Either way, the IJ link
			# cannot continue
			&Janus::delink($ij, "InterJanus network name collision: network $h->{id} already exists");
			return undef;
		}
		RemoteNetwork->new(jlink => $ij, %$h);
	}, '<c' => sub {
		my $ij = shift;
		my $h = {};
		s/^<c// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		# this creates a new object every time because LINK will fail if we
		# give it a cached item
		Channel->new(%$h);
	}, '<n' => sub {
		my $ij = shift;
		my $h = {};
		s/^<n// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		return undef unless ref $h->{net} && $h->{net}->isa('Network');
		# TODO verify that homenet is not forged
		$Janus::gnicks{$h->{gid}} || Nick->new(%$h);
	},
);


sub _kv_pairs {
	my($ij, $h) = @_;
	while (s/^\s+(\S+)=//) {
		my $k = $1;
		my $v_t = substr $_,0,1;
		$v_t = substr $_,0,2 if $v_t eq '<';
		return warn "Cannot find v_t for: $_" unless $v_type{$v_t};
		return warn "Duplicate key $k" if $h->{$k};
		$h->{$k} = $v_type{$v_t}->($ij);
	}
}

1;
