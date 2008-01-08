# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Listener;
use strict;
use warnings;
use Persist 'SocketHandler';
use Pending;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @id :Persist(id) :Arg(id) :Get(id);

sub init_pending {
	my($self, $sock, $peer) = @_;
	my $conf = $Conffile::netconf{$id[$$self]};
	return undef unless $conf;
	my $net = Pending->new(peer => $peer);
	if ($conf->{linktype} =~ /ssl/) {
		IO::Socket::SSL->start_SSL($sock, 
			SSL_server => 1, 
			SSL_startHandshake => 0,
			SSL_key_file => $conf->{keyfile},
			SSL_cert_file => $conf->{certfile},
		);
		$sock->accept_SSL();
	}
	$net;
}

sub dump_sendq { '' }

1;
