package Market::Indicators::ATR;

use strict;
use warnings;

# Implementar el indicador técnico
# Average True Range (ATR).

sub new {

    my ($class, $period) = @_;

    my $self = {

        # Período ATR
        period => $period,

        # Serie completa ATR
        values => [],

        # Último ATR calculado
        last_atr => undef,
    };

    bless $self, $class;

    return $self;
}


# update_last($market_data)
# Calcula incrementalmente el último
# valor ATR usando método Wilder.

sub update_last {

    my ($self, $market_data) = @_;

    # Total de velas disponibles
    my $size = $market_data->size();

    # Se necesitan al menos 2 velas
    return if $size < 2;

    # Vela actual
    my $current = $market_data->last_candle();

    # Vela anterior
    my $previous =
        $market_data->get_candle($size - 2);

    return unless defined $current;
    return unless defined $previous;

    # Cálculo True Range

    # High - Low
    my $hl =
        $current->{high}
        - $current->{low};

    # High - Previous Close
    my $hc =
        abs(
            $current->{high}
            - $previous->{close}
        );

    # Low - Previous Close
    my $lc =
        abs(
            $current->{low}
            - $previous->{close}
        );

    # Selecciona máximo valor
    my $tr = $hl;

    $tr = $hc if $hc > $tr;
    $tr = $lc if $lc > $tr;

    # Wilder ATR incremental

    # Primer ATR
    if (!defined $self->{last_atr}) {

        $self->{last_atr} = $tr;
    }

    # ATR incremental
    else {

        $self->{last_atr} =
            (
                ($self->{last_atr}
                * ($self->{period} - 1))
                + $tr
            ) / $self->{period};
    }

    # Guarda valor calculado
    push @{ $self->{values} },
        $self->{last_atr};
}


# get_values()
# Devuelve todos los valores ATR
# calculados.

sub get_values {

    my ($self) = @_;

    return $self->{values};
}


# reset()
# Reinicia completamente el indicador.

sub reset {

    my ($self) = @_;

    # Limpia valores ATR
    $self->{values} = [];

    # Reinicia ATR incremental
    $self->{last_atr} = undef;
}

1;