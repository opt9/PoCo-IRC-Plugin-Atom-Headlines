package POE::Component::IRC::Plugin::Atom::Headlines;

use strict;
use warnings;
use POE;
use POE::Component::Client::HTTP;
use POE::Component::IRC::Plugin qw(:ALL);
use XML::Atom::Client;
use HTTP::Request;
use vars qw($VERSION);

use Data::Dumper;

$VERSION = '0.01';

sub new {
  my $package = shift;
  my %args = @_;
  $args{lc $_} = delete $args{$_} for keys %args;
  return bless \%args, $package;
}

sub PCI_register {
  my ($self,$irc) = @_;
  $self->{irc} = $irc;
  $irc->plugin_register( $self, 'SERVER', qw(spoof) );
  unless ( $self->{http_alias} ) {
	$self->{http_alias} = join('-', 'ua-atom-headlines', $irc->session_id() );
	$self->{follow_redirects} ||= 2;
	POE::Component::Client::HTTP->spawn(
	   Alias           => $self->{http_alias},
	   Timeout         => 30,
	   FollowRedirects => $self->{follow_redirects},
	);
  }
  $self->{session_id} = POE::Session->create(
	object_states => [ 
	   $self => [ qw(_shutdown _start _get_headline _response) ],
	],
  )->ID();
  $poe_kernel->state( 'get_atom_headline', $self );
  return 1;
}

sub PCI_unregister {
  my ($self,$irc) = splice @_, 0, 2;
  $poe_kernel->state( 'get_atom_headline' );
  $poe_kernel->call( $self->{session_id} => '_shutdown' );
  delete $self->{irc};
  return 1;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{session_id} = $_[SESSION]->ID();
  $kernel->refcount_increment( $self->{session_id}, __PACKAGE__ );
  undef;
}

sub _shutdown {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->alarm_remove_all();
  $kernel->refcount_decrement( $self->{session_id}, __PACKAGE__ );
  $kernel->call( $self->{http_alias} => 'shutdown' );
  undef;
}

sub get_atom_headline {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  $kernel->post( $self->{session_id}, '_get_headline', @_[ARG0..$#_] );
  undef;
}

sub _get_headline {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  my %args;
  if ( ref $_[ARG0] eq 'HASH' ) {
     %args = %{ $_[ARG0] };
  } else {
     %args = @_[ARG0..$#_];
  }
  $args{lc $_} = delete $args{$_} for grep { !/^_/ } keys %args;
  return unless $args{url};
  $args{irc_session} = $self->{irc}->session_id();
  $kernel->post( $self->{http_alias}, 'request', '_response', HTTP::Request->new( GET => $args{url} ), \%args );
  undef;
}

sub _response {
  my ($kernel,$self,$request,$response) = @_[KERNEL,OBJECT,ARG0,ARG1];
  my $args = $request->[1];
  my @params;
  push @params, delete $args->{irc_session}, '__send_event';
  my $result = $response->[0];
  if ( $result->is_success ) {
    my $atom = XML::Atom::Client->new();
    my $feed = $atom->getFeed($args->{'url'});
    my @entries = $feed->entries();
    if (@entries) {
      push @params, 'irc_atomheadlines_items', $args;
      foreach my $item (@entries) {
        push @params, $item->title();
      }
    } else {
      push @params, 'irc_atomheadlines_error', $args, $result->status_line;
    }
    $kernel->post( @params );
    undef;
  }
}

1;
__END__
