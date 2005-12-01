package Slim::Player::Protocols::HTTP;
		  
# $Id$

# SlimServer Copyright (c) 2001-2004 Vidur Apparao, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.  

use strict;
use base qw(IO::Socket::INET);

use File::Spec::Functions qw(:ALL);
use FileHandle;
use IO::Socket qw(:DEFAULT :crlf);
use Scalar::Util qw(blessed);

BEGIN {
	if ($^O =~ /Win32/) {
		*EWOULDBLOCK = sub () { 10035 };
		*EINPROGRESS = sub () { 10036 };

	} else {
		require Errno;
		import Errno qw(EWOULDBLOCK EINPROGRESS);
	}
}

use Slim::Music::Info;
use Slim::Utils::Misc;
use Slim::Utils::Unicode;

sub new {
	my $class = shift;
	my $args  = shift;

	unless ($args->{'url'}) {
		msg("No url passed to Slim::Player::Protocols->new() !\n");
		return undef;
	}

	$args->{'infoUrl'} ||= $args->{'url'};
	
	my $self = $class->open($args);

	if (defined($self)) {
		${*$self}{'url'}     = $args->{'url'};
		${*$self}{'infoUrl'} = $args->{'infoUrl'};
		${*$self}{'client'}  = $args->{'client'};
	}

	return $self;
}

sub open {
	my $class = shift;
	my $args  = shift;

	my $url   = $args->{'url'};

	my ($server, $port, $path, $user, $password) = Slim::Utils::Misc::crackURL($url);

	if (!$server || !$port) {

		$::d_remotestream && msg("Couldn't find server or port in url: [$url]\n");
		return;
	}

	my $timeout = $args->{'timeout'} || Slim::Utils::Prefs::get('remotestreamtimeout');
	my $proxy   = Slim::Utils::Prefs::get('webproxy');

	my $peeraddr = "$server:$port";

	# Don't proxy for localhost requests.
	if ($proxy && $server ne 'localhost' && $server ne '127.0.0.1') {

		$peeraddr = $proxy;
		($server, $port) = split /:/, $proxy;
		$::d_remotestream && msg("Opening connection using proxy $proxy\n");
	}

	$::d_remotestream && msg("Opening connection to $url: [$server on port $port with path $path with timeout $timeout]\n");
		
	my $sock = $class->SUPER::new(
		LocalAddr => $main::localStreamAddr,
		Timeout	  => $timeout,

	) or do {

		msg("Couldn't create socket binding to $main::localStreamAddr with timeout: $timeout - $!\n");
		return undef;
	};

	# store a IO::Select object in ourself.
	# used for non blocking I/O
	${*$sock}{'_sel'} = IO::Select->new($sock);

	# Manually connect, so we can set blocking.
	# I hate Windows.
	Slim::Utils::Misc::blocking($sock, 0) || do {
		$::d_remotestream && msg("Couldn't set non-blocking on socket!\n");
	};

	my $in_addr = inet_aton($server) || do {

		msg("Couldn't resolve IP address for: $server\n");
		close $sock;
		return undef;
	};

	$sock->connect(pack_sockaddr_in($port, $in_addr)) || do {

		my $errnum = 0 + $!;

		if ($errnum != EWOULDBLOCK && $errnum != EINPROGRESS) {
			$::d_remotestream && msg("Can't open socket to [$server:$port]: $errnum: $!\n");
			close $sock;
			return undef;
		}

		() = ${*$sock}{'_sel'}->can_write($timeout) or do {

			$::d_remotestream && msgf("Timeout on connect to [$server:$port]: $errnum: $!\n");
			close $sock;
			return undef;
		};
	};

	return $sock->request($args);
}

sub request {
	my $self = shift;
	my $args = shift;

	my $url     = $args->{'url'};
	my $infoUrl = $args->{'infoUrl'};
	my $post    = $args->{'post'};

	my $class   = ref $self;
	my $request = $self->requestString($url, $post);
	
	$::d_remotestream && msg("Request: $request");

	$self->syswrite($request);

	my $timeout  = $self->timeout();
	my $response = Slim::Utils::Misc::sysreadline($self, $timeout);

	$::d_remotestream && msg("Response: $response");
	
	if (!$response || $response !~ / (\d\d\d)/) {
		$self->close();
		$::d_remotestream && msg("Invalid response code ($response) from remote stream $url\n");
		return undef; 	
	} 

	$response = $1;
	
	if ($response < 200) {
		$::d_remotestream && msg("Invalid response code ($response) from remote stream $url\n");
		$self->close();
		return undef;
	}

	if ($response > 399) {
		$::d_remotestream && msg("Invalid response code ($response) from remote stream $url\n");
		$self->close();
		return undef;
	}
	
	my $redir = '';
	my $ct    = Slim::Music::Info::typeFromPath($infoUrl, 'mp3');

	${*$self}{'contentType'} = $ct;

	while(my $header = Slim::Utils::Misc::sysreadline($self, $timeout)) {

		$::d_remotestream && msg("header: " . $header);

		if ($header =~ /^ic[ey]-name:\s*(.+)$CRLF$/i) {

			${*$self}{'title'} = Slim::Utils::Unicode::utf8decode_guess($1, 'iso-8859-1');
		}

		if ($header =~ /^icy-br:\s*(.+)\015\012$/i) {
			${*$self}{'bitrate'} = $1 * 1000;
		}
		
		if ($header =~ /^icy-metaint:\s*(.+)$CRLF$/) {
			${*$self}{'metaInterval'} = $1;
			${*$self}{'metaPointer'} = 0;
		}
		
		if ($header =~ /^Location:\s*(.*)$CRLF$/i) {
			$redir = $1;
		}

		if ($header =~ /^Content-Type:\s*(.*)$CRLF$/i) {
			my $contentType = $1;
			
			if (($contentType =~ /text/i) && !($contentType =~ /text\/xml/i)) {
				# webservers often lie about playlists.  This will
				# make it guess from the suffix.  (unless text/xml)
				$contentType = '';
			}
			
			${*$self}{'contentType'} = $contentType;
		}
		
		if ($header =~ /^Content-Length:\s*(.*)$CRLF$/i) {

			${*$self}{'contentLength'} = $1;
		}

		if ($header eq $CRLF) { 
			$::d_remotestream && msg("Recieved final blank line...\n");
			last; 
		}
	}

	if ($redir) {
		# Redirect -- maybe recursively?

		# Close the existing handle and refcnt-- to avoid keeping the
		# socket in a CLOSE_WAIT state and leaking.
		$self->close();

		$::d_remotestream && msg("Redirect to: $redir\n");

		return $class->open({
			'url'     => $redir,
			'infoUrl' => $redir,
			'post'    => $post,
		});
	}

	$::d_remotestream && msg("opened stream!\n");

	return $self;
}

# small wrapper to grab the content in a non-blocking fashion.
sub content {
	my $self   = shift;
	my $length = shift || $self->contentLength() || Slim::Web::HTTP::MAXCHUNKSIZE();

	my $content = '';
	my $bytesread = $self->sysread($content, $length);

	while ((defined($bytesread) && ($bytesread != 0)) || (!defined($bytesread) && $! == EWOULDBLOCK )) {

		::idleStreams(0.1);

		$bytesread = $self->sysread($content, $length);
	}

	return $content;
}

sub sysread {
	my $self = $_[0];
	my $chunkSize = $_[2];

	my $metaInterval = ${*$self}{'metaInterval'};
	my $metaPointer  = ${*$self}{'metaPointer'};

	if ($metaInterval && ($metaPointer + $chunkSize) > $metaInterval) {

		$chunkSize = $metaInterval - $metaPointer;
		$::d_source && msg("reduced chunksize to $chunkSize for metadata\n");
	}

	my $readLength = CORE::sysread($self, $_[1], $chunkSize, length($_[1]));

	if ($metaInterval && $readLength) {

		$metaPointer += $readLength;
		${*$self}{'metaPointer'} = $metaPointer;

		# handle instream metadata for shoutcast/icecast
		if ($metaPointer == $metaInterval) {

			$self->readMetaData();

			${*$self}{'metaPointer'} = 0;

		} elsif ($metaPointer > $metaInterval) {

			msg("Problem: the shoutcast metadata overshot the interval.\n");
		}	
	}

	return $readLength;
}

sub syswrite {
	my $self = $_[0];
	my $data = $_[1];

	my $length = length $data;

	while (length $data > 0) {

		return unless ${*$self}{'_sel'}->can_write(0.05);

		local $SIG{'PIPE'} = 'IGNORE';

		my $wc = CORE::syswrite($self, $data, length($data));

		if (defined $wc) {

			substr($data, 0, $wc) = '';

		} elsif ($! == EWOULDBLOCK) {

			return;
		}
	}

	return $length;
}

sub readMetaData {
	my $self = shift;
	my $client = ${*$self}{'client'};

	my $metadataSize = 0;
	my $byteRead = 0;

	while ($byteRead == 0) {

		$byteRead = $self->SUPER::sysread($metadataSize, 1);

		if ($!) {
			if ($! ne "Unknown error" && $! != EWOULDBLOCK) {
			 	$::d_remotestream && msg("Metadata byte not read! $!\n");  
			 	return;
			 } else {
			 	$::d_remotestream && msg("Metadata byte not read, trying again: $!\n");  
			 }			 
		}

		$byteRead = defined $byteRead ? $byteRead : 0;
	}
	
	$metadataSize = ord($metadataSize) * 16;
	
	$::d_remotestream && msg("metadata size: $metadataSize\n");

	if ($metadataSize > 0) {
		my $metadata;
		my $metadatapart;
		
		do {
			$metadatapart = '';
			$byteRead = $self->SUPER::sysread($metadatapart, $metadataSize);

			if ($!) {
				if ($! ne "Unknown error" && $! != EWOULDBLOCK) {
					$::d_remotestream && msg("Metadata bytes not read! $!\n");  
					return;
				} else {
					$::d_remotestream && msg("Metadata bytes not read, trying again: $!\n");  
				}			 
			}

			$byteRead = 0 if (!defined($byteRead));
			$metadataSize -= $byteRead;	
			$metadata .= $metadatapart;	

		} while ($metadataSize > 0);			

		$::d_remotestream && msg("metadata: $metadata\n");

		my $url   = $self->url;
		my $title = $self->parseMetadata($client, $url, $metadata);

		${*$self}{'title'} = $title;

		# new song, so reset counters
		$client->songBytes(0);
	}
}

sub parseMetadata {
	my $self     = shift;
	my $client   = shift;
	my $url      = shift;
	my $metadata = shift;

	if ($metadata =~ (/StreamTitle=\'(.*?)\'(;|$)/)) {

		my $newTitle = Slim::Utils::Unicode::utf8decode_guess($1, 'iso-8859-1');

		my $oldTitle = $self->title;

		# capitalize titles that are all lowercase
		if (lc($newTitle) eq $newTitle) {
			$newTitle =~ s/ (
					  (^\w)    #at the beginning of the line
					  |        # or
					  (\s\w)   #preceded by whitespace
					  |        # or
					  (-\w)   #preceded by dash
					  )
				/\U$1/xg;
		}

		if ($newTitle && $oldTitle ne $newTitle) {

			Slim::Music::Info::setCurrentTitle($url, $newTitle);

			for my $everybuddy ( $client, Slim::Player::Sync::syncedWith($client)) {
				$everybuddy->update();
			}
		}

		$::d_remotestream && msg("shoutcast title = $newTitle\n");

		return $newTitle;
	}

	return undef;
}

sub url {
	my $self = shift;

	return ${*$self}{'infoUrl'};
}

sub title {
	my $self = shift;

	return ${*$self}{'title'};
}

sub bitrate {
	my $self = shift;

	return ${*$self}{'bitrate'};
}

sub contentLength {
	my $self = shift;

	return ${*$self}{'contentLength'};
}

sub contentType {
	my $self = shift;

	return ${*$self}{'contentType'};
}

sub skipForward {
	return 0;
}

sub skipBack {
	return 0;
}

sub DESTROY {
	my $self = shift;
 
	if ($::d_remotestream && defined ${*$self}{'url'}) {

		my $class = ref($self);

		msgf("%s - in DESTROY\n", $class);
		msgf("%s About to close socket to: [%s]\n", $class, ${*$self}{'url'});
	}

	$self->close;
}

sub close {
	my $self = shift;

	# Remove the reference to ourselves that is the IO::Select handle.
	if (defined $self && defined ${*$self}{'_sel'}) {
		${*$self}{'_sel'}->remove($self);
		${*$self}{'_sel'} = undef;
	}

	$self->SUPER::close;
}

# HTTP direct streaming disabled for SlimServer
sub canDirectStreamDisabled {
	my $classOrSelf = shift;
	my $url = shift;

	return $url;
}

sub requestString {
	my $classOrSelf = shift;
	my $url = shift;
	my $post = shift;

	my ($server, $port, $path, $user, $password) = Slim::Utils::Misc::crackURL($url);
 
	my $proxy = Slim::Utils::Prefs::get('webproxy');
	if ($proxy && $server ne 'localhost' && $server ne '127.0.0.1') {
		$path = "http://$server:$port$path";
	}

	my $type = $post ? 'POST' : 'GET';

	# Although the port can be part of the Host: header, some hosts (such
	# as online.wsj.com don't like it, and will infinitely redirect.
	# According to the spec, http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html
	# The port is optional if it's 80, so follow that rule.
	my $host = $port == 80 ? $server : "$server:$port";

	# make the request
	my $request = join($CRLF, (
		"$type $path HTTP/1.0",
		"Accept: */*",
		"Cache-Control: no-cache",
		"User-Agent: " . Slim::Utils::Misc::userAgentString(),
		"Icy-MetaData: 1",
		"Connection: close",
		"Host: $host" . $CRLF
	));
	
	if (defined($user) && defined($password)) {
		$request .= "Authorization: Basic " . MIME::Base64::encode_base64($user . ":" . $password,'') . $CRLF;
	}

	# Send additional information if we're POSTing
	if ($post) {

		$request .= "Content-Type: application/x-www-form-urlencoded$CRLF";
		$request .= sprintf("Content-Length: %d$CRLF", length($post));
		$request .= $CRLF . $post . $CRLF;

	} else {
		$request .= $CRLF;
	}

	return $request;
}

1;

__END__


# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
