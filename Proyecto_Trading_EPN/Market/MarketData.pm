package Market::MarketData;

use strict;
use warnings;


# Gestionar almacenamiento y acceso de datos
# OHLCV junto con temporalidades del mercado.

sub new {

    my ($class) = @_;

    my $self = {

        # Almacena velas por timeframe
        data => {
            '1m'  => [],
            '5m'  => [],
            '15m' => [],
        },

        # Timeframe actualmente activo
        active_tf => '1m',
    };

    bless $self, $class;

    return $self;
}

# get_data()
# Devuelve toda la estructura de datos.

sub get_data {

    my ($self) = @_;

    return $self->{data};
}

# add_candle($candle)
# Agrega una nueva vela al timeframe base.

sub add_candle {

    my ($self, $candle) = @_;

    return unless defined $candle;

    # Inserta vela en timeframe principal
    push @{ $self->{data}->{'1m'} }, $candle;
}


# build_tf_candles($minutes)
# Construye velas agregadas para
# una temporalidad específica.

sub build_tf_candles {

    my ($self, $minutes) = @_;

    # Datos fuente desde 1m
    my $source = $self->{data}->{'1m'};

    my @result;

    # Recorre bloques de velas
    for (my $i = 0; $i < @$source; $i += $minutes) {

        my $end = $i + $minutes - 1;

        # Evita índices fuera de rango
        $end = $#$source if $end > $#$source;

        my @chunk = @$source[$i .. $end];

        next unless @chunk;

        # Inicializa high/low
        my $high = $chunk[0]->{high};
        my $low  = $chunk[0]->{low};

        my $volume = 0;

        # Busca máximos/mínimos
        for my $candle (@chunk) {

            $high = $candle->{high}
                if $candle->{high} > $high;

            $low = $candle->{low}
                if $candle->{low} < $low;

            # Acumula volumen
            $volume += $candle->{volume};
        }

        # Construcción OHLC agregada
        my $new_candle = {

            timestamp => $chunk[0]->{timestamp},

            open  => $chunk[0]->{open},
            close => $chunk[-1]->{close},

            high => $high,
            low  => $low,

            volume => $volume,
        };

        push @result, $new_candle;
    }

    # Guarda timeframe generado
    $self->{data}->{"${minutes}m"} = \@result;
}


# build_timeframes()
# Reconstruye todas las temporalidades
# derivadas desde 1m.

sub build_timeframes {

    my ($self) = @_;

    $self->build_tf_candles(5);
    $self->build_tf_candles(15);
}


# set_timeframe($tf)
# Cambia la temporalidad activa.

sub set_timeframe {

    my ($self, $tf) = @_;

    # Valida timeframe
    die "Invalid timeframe"
        unless exists $self->{data}->{$tf};

    $self->{active_tf} = $tf;
}


# _active_array()
# Devuelve el array correspondiente
# al timeframe activo.

sub _active_array {

    my ($self) = @_;

    return $self->{data}->{ $self->{active_tf} };
}


# get_slice($start, $end)
# Devuelve una ventana parcial de velas.

sub get_slice {

    my ($self, $start, $end) = @_;

    my $array = $self->_active_array();

    # Protección de límites
    $start = 0 if $start < 0;
    $end   = $#$array if $end > $#$array;

    return [ @$array[$start .. $end] ];
}


# get_candle($index)
# Obtiene una vela por índice.

sub get_candle {

    my ($self, $index) = @_;

    my $array = $self->_active_array();

    return $array->[$index];
}

# size()
# Devuelve total de velas activas.

sub size {

    my ($self) = @_;

    my $array = $self->_active_array();

    return scalar @$array;
}


# last_candle()
# Devuelve última vela activa.

sub last_candle {

    my ($self) = @_;

    my $array = $self->_active_array();

    return $array->[-1];
}


# last_index()
# Devuelve último índice disponible.

sub last_index {

    my ($self) = @_;

    return $self->size() - 1;
}


# get_timestamp($index)
# Obtiene timestamp de una vela.

sub get_timestamp {

    my ($self, $index) = @_;

    my $candle = $self->get_candle($index);

    return unless defined $candle;

    return $candle->{timestamp};
}


# merge_delta_row($row)
# Actualiza o inserta datos
# incrementalmente.

sub merge_delta_row {

    my ($self, $row) = @_;

    my $candles = $self->{data}->{'1m'};

    return unless defined $row;

    # Actualiza vela existente
    if (
        @$candles &&
        $candles->[-1]->{timestamp} eq $row->{timestamp}
    ) {

        $candles->[-1] = $row;
    }

    # Inserta nueva vela
    else {

        push @$candles, $row;
    }

    # Reconstruye temporalidades
    $self->build_timeframes();
}


# compute_time_anchors()
# Calcula puntos de referencia
# temporales para eje X.

sub compute_time_anchors {

    my ($self) = @_;

    my $array = $self->_active_array();

    my @anchors;

    # Genera anchors cada 20 velas
    for (my $i = 0; $i < @$array; $i += 20) {

        push @anchors, {

            index => $i,

            timestamp => $array->[$i]->{timestamp},
        };
    }

    return \@anchors;
}

1;