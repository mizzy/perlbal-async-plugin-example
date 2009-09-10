package Perlbal::Plugin::Async;

use strict;
use warnings;

sub register {
    my ( $class, $svc ) = @_;

    $svc->register_hook(
        'Async' => 'start_proxy_request', \&request_db,
    );

    return 1;
}

sub request_db {
    my Perlbal::ClientProxy $client = shift;

    My::Drizzle->new(
        callback => sub {
            $client->{complete_start_proxy_request} = 1;
            $client->handle_request;
        },
    );

    return 1;
}

sub load   { 1 }
sub unload { 1 }


package My::Drizzle;

use base 'Danga::Socket';
use fields qw(con callback);
use Net::Drizzle ':constants';
use IO::Poll qw/POLLOUT/;

my $drizzle = Net::Drizzle->new;
$drizzle->add_options(DRIZZLE_NON_BLOCKING);

my $con = $drizzle->con_create;
$con->add_options(DRIZZLE_CON_MYSQL);
$con->set_charset(8);
$con->set_db('test');

sub new {
    my My::Drizzle $self = shift;
    my %args = @_;

    $self = fields::new($self) unless ref $self;

    $self->{con}      = $con->clone;
    $self->{callback} = $args{callback};

    $self->{con}->query_add('SELECT sleep(10)');

    while (1) {
        my $ret = $self->poll_db();
        if ($ret == DRIZZLE_RETURN_IO_WAIT) {
            last;
        }
    }

    die "cannot connect?" if $self->{con}->fd < 0;
    $self->SUPER::new( $self->{con}->fh );
    $self->watch_read(1);

    return $self;
}

sub event_read {
    my $self = shift;
    $self->poll_db();
}

sub poll_db {
    my ($self, $mode) = @_;

    $self->{con}->set_revents( POLLOUT );

    my $drizzle       = $self->{con}->drizzle;
    my ($ret, $query) = $drizzle->query_run();

    if ($ret != DRIZZLE_RETURN_IO_WAIT && $ret != DRIZZLE_RETURN_OK) {
        die "query error: " . $drizzle->error(). '('.$drizzle->error_code .')';
    }

    if ($query) {
        my $result = $query->result;
        my $callback = $self->{callback};
        if (defined $callback) {
            $callback->($query->result);
        }
    }

    return $ret;
}

1;
