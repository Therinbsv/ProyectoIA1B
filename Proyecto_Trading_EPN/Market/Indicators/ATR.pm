package Market::Indicators::ATR;
# Implementa el indicador Average True Range (ATR).
# Calcula volatilidad basada en precios historicos usando el metodo de Wilder.
# Formula TR = max(High-Low, |High-PrevClose|, |Low-PrevClose|)
# ATR[i] = (ATR[i-1] * (period-1) + TR[i]) / period   (suavizado de Wilder)
use strict;
use warnings;
use List::Util qw(max);

sub new {
    my ($class, $period) = @_;
    $period = 14 unless defined $period && $period > 0;
    my $self = {
        period => $period,
        values => [],   # serie completa de ATR (undef para primeras period-1 velas)
        _tr    => [],   # serie de True Range
    };
    bless $self, $class;
    return $self;
}

# Actualiza el ATR con la vela en la posicion $index del market_data.
# Permite calculo incremental correcto vela por vela.
# Input: $market_data (objeto MarketData), $index (entero, posicion de la vela)
sub update_last {
    my ($self, $market_data, $index) = @_;

    # Si no se pasa indice, inferir como el siguiente a calcular
    if (!defined $index) {
        $index = scalar @{ $self->{values} };
    }

    my $total = $market_data->size();
    return if $index >= $total;

    my $c    = $market_data->get_candle($index);
    my $high = $c->{high};
    my $low  = $c->{low};
    my $p    = $self->{period};

    my $tr;
    if ($index == 0) {
        # Primera vela: TR = High - Low
        $tr = $high - $low;
    } else {
        my $prev_close = $market_data->get_candle($index - 1)->{close};
        $tr = max($high - $low,
                  abs($high - $prev_close),
                  abs($low  - $prev_close));
    }
    push @{ $self->{_tr} }, $tr;

    my $i = scalar @{ $self->{values} };   # posicion actual en el array de valores

    if ($i < $p - 1) {
        # Aun no hay suficientes velas: valor indefinido
        push @{ $self->{values} }, undef;
    } elsif ($i == $p - 1) {
        # Primera ATR valida: SMA de los primeros $p TR
        my $sum = 0;
        $sum += $_ for @{ $self->{_tr} };
        push @{ $self->{values} }, $sum / $p;
    } else {
        # Suavizado de Wilder
        my $prev_atr = $self->{values}->[-1] // 0;
        my $new_atr  = ($prev_atr * ($p - 1) + $tr) / $p;
        push @{ $self->{values} }, $new_atr;
    }
}

# Devuelve la serie completa de valores ATR.
# Output: arrayref (puede contener undef en las primeras period-1 posiciones)
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# Reinicia el indicador (util al cambiar timeframe).
sub reset {
    my ($self) = @_;
    $self->{values} = [];
    $self->{_tr}    = [];
}

1;