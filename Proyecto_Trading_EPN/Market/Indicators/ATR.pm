package Market::Indicators::ATR;
use strict;
use warnings;

sub new {
    my ($class, $period) = @_;
    # Validación: el período debe ser un entero positivo.
    die "ATR period must be a positive integer"
        unless defined $period && $period =~ /^\d+$/ && $period > 0;

    # Estructura interna del objeto (hashref con claves privadas _algo).
    my $self = {
        period      => $period,   # período del ATR 
        values      => [],        # array donde guardaremos los ATR calculados
        _tr_sum     => 0,         # suma acumulada de True Ranges para el warm-up
        _last_close => undef,     # cierre de la vela anterior
        _last_atr   => undef,     # último ATR calculado
        _count      => 0,         # cuántas velas hemos procesado en total (para saber si estamos en warm-up, semilla o régimen normal)
    };
    bless $self, $class;        
    return $self;
}

# update_last(): Procesa UNA nueva vela y actualiza el ATR incrementalmente (O(1)).
sub update_last {
    my ($self, $market_data, $index) = @_;

    # Obtener la vela: si nos dieron índice, pedimos esa; si no, la última.
    my $candle = defined $index ? $market_data->get_candle($index) : $market_data->last_candle();
    return unless $candle;  # si no hay vela (ej: datos vacíos), salir sin hacer nada

    # Extraer OHLC: asumimos que la vela es [timestamp, open, high, low, close, volume]
    my $high  = $candle->[2];
    my $low   = $candle->[3];
    my $close = $candle->[4];

    my $tr;   # True Range de esta vela

    # Calcular TR:
    if (defined $self->{_last_close}) {
        # No es la primera vela: necesitamos el cierre anterior.
        my $prev_close = $self->{_last_close};
        my $hl  = $high - $low;                     # rango del día: high - low
        my $hpc = abs($high - $prev_close);         # |high - prev_close|
        my $lpc = abs($low  - $prev_close);         # |low  - prev_close|
        $tr = $hl;                                  # empezamos con el rango del día
        $tr = $hpc if $hpc > $tr;                   # actualizar si |high-prev| es mayor
        $tr = $lpc if $lpc > $tr;                   # actualizar si |low-prev| es mayor
    } else {
        # Primera vela de la serie: TR = high - low (no hay cierre anterior)
        $tr = $high - $low;
    }

    # Incrementar contador de velas procesadas
    $self->{_count}++;
    my $period = $self->{period};

    # Lógica del suavizado de Wilder:
    if ($self->{_count} < $period) {
        # Fase de warm-up: aún no tenemos suficientes velas para calcular ATR.
        # Solo acumulamos TR en _tr_sum y guardamos undef en la serie.
        $self->{_tr_sum} += $tr;
        push @{ $self->{values} }, undef;
    }
    elsif ($self->{_count} == $period) {
        # Vela número 'period': semilla del ATR = promedio simple de los TR acumulados.
        $self->{_tr_sum} += $tr;                     # añadir el TR de esta vela a la suma
        my $atr = $self->{_tr_sum} / $period;        # promedio simple = suma / período
        $self->{_last_atr} = $atr;                   # guardar para la próxima iteración
        push @{ $self->{values} }, $atr;             # guardar en la serie
    }
    else {
        # Fase normal (más de 'period' velas): fórmula recursiva de Wilder.
        # ATR_t = (ATR_{t-1} * (period-1) + TR_t) / period
        my $atr = ($self->{_last_atr} * ($period - 1) + $tr) / $period;
        $self->{_last_atr} = $atr;                   # actualizar para la próxima
        push @{ $self->{values} }, $atr;             # guardar en la serie
    }

    # Guardar el cierre actual como _last_close para la próxima vela.
    $self->{_last_close} = $close;
    return;
}

# get_values(): Devuelve la serie completa de ATR (arrayref).
sub get_values {
    my ($self) = @_;
    return $self->{values};
}

# reset(): Reinicia completamente el estado interno del indicador.
sub reset {
    my ($self) = @_;
    # Reinicia el estado incremental. Lo invoca IndicatorManager::reset_all al
    # cambiar de timeframe; tras esto se recalcula vela por vela 
    $self->{values}      = [];
    $self->{_tr_sum}     = 0;
    $self->{_last_close} = undef;
    $self->{_last_atr}   = undef;
    $self->{_count}      = 0;
    return;
}

1;