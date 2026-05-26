package Market::Indicators::ATR;

use strict;
use warnings;

sub new {
    my ($class, $period) = @_;

    my $self = {

        period => $period,

        values => [],

        last_atr => undef,
    };

    bless $self, $class;

    return $self;
}

# Actualiza ATR incrementalmente
sub update_last {
    my ($self, $market_data) = @_;

    my $size = $market_data->size();

    return if $size < 2;

    my $current = $market_data->last_candle();

    my $previous =
        $market_data->get_candle($size - 2);

    return unless defined $current;
    return unless defined $previous;

    my $hl =
        $current->{high} - $current->{low};

    my $hc =
        abs(
            $current->{high}
            - $previous->{close}
        );

    my $lc =
        abs(
            $current->{low}
            - $previous->{close}
        );

    my $tr = $hl;

    $tr = $hc if $hc > $tr;
    $tr = $lc if $lc > $tr;

    # Wilder ATR incremental
    if (!defined $self->{last_atr}) {

        $self->{last_atr} = $tr;
    }
    else {

        $self->{last_atr} =
            (
                ($self->{last_atr}
                * ($self->{period} - 1))
                + $tr
            ) / $self->{period};
    }

    push @{ $self->{values} },
        $self->{last_atr};
}

# Devuelve todos los valores ATR
sub get_values {
    my ($self) = @_;

    return $self->{values};
}

# Reinicia indicador
sub reset {
    my ($self) = @_;

    $self->{values} = [];

    $self->{last_atr} = undef;
}

1;