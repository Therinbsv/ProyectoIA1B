package Market::MarketData;
# Clase responsable de almacenar y gestionar los datos de mercado (OHLCV).
# Garantiza sincronizacion temporal, acceso eficiente por indice
# y actualizacion incremental de datos.
use strict;
use warnings;
use Time::Moment;

sub new {
    my ($class) = @_;
    my $self = {
        data      => {},   # hash de tf => [ {time,open,high,low,close,volume}, ... ]
        active_tf => '1m', # temporalidad activa por defecto
    };
    bless $self, $class;
    return $self;
}

# Devuelve la estructura completa de datos (todos los timeframes).
sub get_data {
    my ($self) = @_;
    return $self->{data};
}

# Agrega una vela nueva al timeframe activo (1m).
# Input: hashref { time, open, high, low, close, volume }
sub add_candle {
    my ($self, $candle) = @_;
    # Forzar numericos
    $candle->{open}   += 0;
    $candle->{high}   += 0;
    $candle->{low}    += 0;
    $candle->{close}  += 0;
    $candle->{volume} += 0;
    push @{ $self->{data}{'1m'} }, $candle;
}

# Construye velas agregadas para un timeframe especifico a partir de 1m.
# Input: $tf (ej: '5m', '15m')
sub build_tf_candles {
    my ($self, $tf) = @_;
    my $minutes;
    if    ($tf eq '5m')  { $minutes = 5; }
    elsif ($tf eq '15m') { $minutes = 15; }
    else { die "build_tf_candles: timeframe '$tf' no soportado\n"; }

    my $base = $self->{data}{'1m'};
    return unless $base && @$base;

    my @aggr;
    my $block      = undef;
    my $block_time = undef;

    for my $c (@$base) {
        my $tm = Time::Moment->from_string($c->{time});
        if (!defined $block) {
            $block = {
                time   => $c->{time},
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume},
            };
            $block_time = $tm;
            next;
        }
        my $diff = $tm->delta_minutes($block_time);
        if ($diff < $minutes) {
            $block->{high}   = $c->{high}  if $c->{high}  > $block->{high};
            $block->{low}    = $c->{low}   if $c->{low}   < $block->{low};
            $block->{close}  = $c->{close};
            $block->{volume} += $c->{volume};
        } else {
            push @aggr, $block;
            $block = {
                time   => $c->{time},
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume},
            };
            $block_time = $tm;
        }
    }
    push @aggr, $block if defined $block;
    $self->{data}{$tf} = \@aggr;
}

# Construye todos los timeframes disponibles (5m y 15m a partir de 1m).
sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles('5m');
    $self->build_tf_candles('15m');
}

# Selecciona la temporalidad activa.
# Input: $tf ('1m', '5m', '15m')
sub set_timeframe {
    my ($self, $tf) = @_;
    die "Timeframe '$tf' no existe en los datos\n"
        unless exists $self->{data}{$tf};
    $self->{active_tf} = $tf;
}

# Devuelve el array de velas del timeframe activo (abstraccion interna clave).
sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{active_tf} } // [];
}

# Devuelve un subconjunto de velas [start..end] del timeframe activo.
# Input: $start (indice inicio), $end (indice fin)
# Output: arrayref de velas
sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr = $self->_active_array();
    $start = 0        if $start < 0;
    $end   = $#$arr   if $end > $#$arr;
    return []         if $start > $end;
    return [ @{$arr}[$start .. $end] ];
}

# Obtiene una vela por indice.
sub get_candle {
    my ($self, $index) = @_;
    return $self->_active_array()->[$index];
}

# Numero total de velas en el timeframe activo.
sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array() };
}

# Devuelve la ultima vela del timeframe activo.
sub last_candle {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return $arr->[-1];
}

# Devuelve el indice de la ultima vela.
sub last_index {
    my ($self) = @_;
    return $self->size() - 1;
}

# Obtiene el timestamp de una vela por indice.
sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return $c ? $c->{time} : undef;
}

# Actualiza o inserta datos incrementales (streaming).
# Si el timestamp es igual al ultimo, actualiza; si no, agrega nueva vela.
sub merge_delta_row {
    my ($self, $row) = @_;
    $row->{open}   += 0;
    $row->{high}   += 0;
    $row->{low}    += 0;
    $row->{close}  += 0;
    $row->{volume} += 0;
    my $arr  = $self->_active_array();
    my $last = $arr->[-1];
    if ($last) {
        my $last_tm = Time::Moment->from_string($last->{time});
        my $new_tm  = Time::Moment->from_string($row->{time});
        if ($last_tm->epoch == $new_tm->epoch) {
            $last->{high}    = $row->{high}  if $row->{high}  > $last->{high};
            $last->{low}     = $row->{low}   if $row->{low}   < $last->{low};
            $last->{close}   = $row->{close};
            $last->{volume} += $row->{volume};
            return;
        }
    }
    push @$arr, $row;
}

# Calcula puntos clave de tiempo para el eje X.
# Devuelve arrayref de { index => $i, label => $str }
# Genera una etiqueta cada vez que cambia la hora o el dia.
sub compute_time_anchors {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return [] unless $arr && @$arr;

    my @anchors;
    my $prev_hour = -1;
    my $prev_day  = -1;

    for my $i (0 .. $#$arr) {
        my $tm   = Time::Moment->from_string($arr->[$i]{time});
        my $hour = $tm->hour;
        my $min  = $tm->minute;
        my $day  = $tm->day_of_month;

        # Etiqueta cuando cambia la hora (cada :00) o el dia
        next unless ($min == 0 || ($hour != $prev_hour && $day == $prev_day)
                     || $day != $prev_day || $i == 0);

        my $label;
        if ($day != $prev_day && $hour == 0) {
            $label = $tm->strftime('%a %d');
        } elsif ($day != $prev_day) {
            $label = $tm->strftime('%b%d');
        } else {
            $label = $tm->strftime('%H:%M');
        }

        push @anchors, { index => $i, label => $label };
        $prev_hour = $hour;
        $prev_day  = $day;
    }
    return \@anchors;
}

1;