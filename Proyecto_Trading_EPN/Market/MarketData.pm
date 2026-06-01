package Market::MarketData;      # Declara el espacio de nombres del módulo de datos
use strict;                      # Obliga a declarar variables
use warnings;                    # Muestra advertencias
use Time::Moment;                # Módulo para manejar fechas/horas de forma robusta

# ============================================================================
# new(): Constructor del gestor de datos de mercado
# ============================================================================
sub new {
    my ($class) = @_;                     # $class es 'Market::MarketData'
    my $self = {
        # Estructura para almacenar velas en diferentes temporalidades
        data      => { '1m' => [], '5m' => [], '15m' => [] },
        active_tf => '1m',                # Temporalidad activa (por defecto 1 minuto)
    };
    bless $self, $class;                  # "Bendecir" el hashref como objeto
    return $self;                         # Devolver el objeto recién creado
}

# ============================================================================
# get_data(): Devuelve el array de velas de la temporalidad activa
# ============================================================================
sub get_data {
    my ($self) = @_;
    return $self->_active_array();        # Delegar en el método privado
}

# ============================================================================
# add_candle(): Añade una vela al array de 1 minuto (datos brutos)
# ============================================================================
sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}->{'1m'} }, $candle;   # Añadir al final del array de 1m
}

# ============================================================================
# build_tf_candles(): Construye velas de mayor temporalidad a partir de 1m
# ============================================================================
sub build_tf_candles {
    my ($self, $tf) = @_;
    
    # Obtener los datos base (1 minuto)
    my $base_data = $self->{data}->{'1m'};
    return unless @$base_data;            # Si no hay datos, salir

    # Determinar cuántas velas de 1 minuto forman una vela de la nueva temporalidad
    my $group_size = ($tf eq '5m') ? 5 : ($tf eq '15m') ? 15 : 1;
    my @aggregated;                       # Array para almacenar las velas agregadas
    
    # Iterar sobre las velas de 1 minuto en saltos de 'group_size'
    for (my $i = 0; $i < @$base_data; $i += $group_size) {
        # Calcular el índice final del grupo (sin pasarse del array)
        my $end = $i + $group_size - 1;
        $end = $#$base_data if $end > $#$base_data;
        
        # Extraer el slice de velas de 1 minuto que forman este grupo
        my @slice = @$base_data[$i .. $end];
        
        # Timestamp: usar el de la primera vela del grupo
        my $ts = $slice[0]->[0];
        
        # Open: usar el de la primera vela
        my $open = $slice[0]->[1];
        
        # Close: usar el de la última vela
        my $close = $slice[-1]->[4];
        
        # High, Low, Volume: inicializar con los valores de la primera vela
        my ($high, $low, $vol) = ($slice[0]->[2], $slice[0]->[3], 0);
        
        # Recorrer todas las velas del grupo para calcular máximo, mínimo y suma
        for my $c (@slice) {
            $high = $c->[2] if $c->[2] > $high;   # Actualizar high si es mayor
            $low  = $c->[3] if $c->[3] < $low;    # Actualizar low si es menor
            $vol += $c->[5];                      # Sumar volumen
        }
        
        # Añadir la vela agregada al array de la nueva temporalidad
        push @aggregated, [$ts, $open, $high, $low, $close, $vol];
    }
    
    # Guardar el resultado en el hash de datos
    $self->{data}->{$tf} = \@aggregated;
}

# ============================================================================
# build_timeframes(): Construye ambas temporalidades (5m y 15m) de una vez
# ============================================================================
sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles('5m');    # Construir velas de 5 minutos
    $self->build_tf_candles('15m');   # Construir velas de 15 minutos
}

# ============================================================================
# set_timeframe(): Cambia la temporalidad activa
# ============================================================================
sub set_timeframe {
    my ($self, $tf) = @_;
    # Verificar que la temporalidad exista antes de cambiar
    $self->{active_tf} = $tf if exists $self->{data}->{$tf};
}

# ============================================================================
# _active_array(): Devuelve el array de velas de la temporalidad activa
# ============================================================================
sub _active_array {
    my ($self) = @_;
    return $self->{data}->{ $self->{active_tf} };
}

# ============================================================================
# get_slice(): Devuelve una porción de velas (para la ventana visible)
# ============================================================================
sub get_slice {
    my ($self, $start, $end) = @_;
    
    # Obtener el array de la temporalidad activa
    my $arr = $self->_active_array();
    
    # Si no hay datos, devolver array vacío
    return [] unless @$arr;
    
    # Si los índices no están definidos o start > end, devolver array vacío
    return [] if !defined $start || !defined $end || $start > $end;

    # Construir el slice
    my @slice;
    for my $i ($start .. $end) {
        # Si el índice está dentro del rango del array, tomar la vela
        # Si no, poner undef (para mantener el tamaño correcto)
        push @slice, ($i >= 0 && $i <= $#$arr) ? $arr->[$i] : undef;
    }
    return \@slice;
}

# ============================================================================
# get_candle(): Devuelve una vela específica por su índice
# ============================================================================
sub get_candle {
    my ($self, $index) = @_;
    return $self->_active_array()->[$index];
}

# ============================================================================
# size(): Devuelve la cantidad total de velas en la temporalidad activa
# ============================================================================
sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array() };
}

# ============================================================================
# last_candle(): Devuelve la última vela (más reciente) de la temporalidad activa
# ============================================================================
sub last_candle {
    my ($self) = @_;
    return $self->_active_array()->[-1];    # El elemento -1 es el último del array
}

# ============================================================================
# last_index(): Devuelve el índice de la última vela (size - 1)
# ============================================================================
sub last_index {
    my ($self) = @_;
    return $self->size() - 1;
}

# ============================================================================
# get_timestamp(): Devuelve el timestamp de una vela específica
# ============================================================================
sub get_timestamp {
    my ($self, $index) = @_;
    my $candle = $self->get_candle($index);
    return $candle ? $candle->[0] : undef;   # El timestamp está en la posición 0
}

# ============================================================================
# merge_delta_row(): Actualiza la última vela en tiempo real (streaming)
# ============================================================================
sub merge_delta_row {
    my ($self, $row) = @_;
    
    # Obtener el array de velas de 1 minuto (base)
    my $arr = $self->{data}->{'1m'};
    
    # Si hay al menos una vela y el timestamp coincide con la última
    if (@$arr && $arr->[-1]->[0] eq $row->[0]) {
        my $last = $arr->[-1];          # Referencia a la última vela
        
        # Actualizar high: tomar el máximo entre el actual y el nuevo
        $last->[2] = $row->[2] if $row->[2] > $last->[2];
        
        # Actualizar low: tomar el mínimo entre el actual y el nuevo
        $last->[3] = $row->[3] if $row->[3] < $last->[3];
        
        # Actualizar close siempre (el precio más reciente)
        $last->[4] = $row->[4];
        
        # Sumar volumen
        $last->[5] += $row->[5];
    } else {
        # Es una nueva vela, añadirla al final
        $self->add_candle($row);
    }
}

# ============================================================================
# compute_time_anchors — puntos clave de tiempo para el eje/etiquetas (capa de datos)
# ============================================================================
sub compute_time_anchors {
    my ($self) = @_;
    
    # Obtener el array de velas de la temporalidad activa
    my $arr = $self->_active_array();
    my @anchors;    # Array donde guardaremos los puntos de anclaje

    # Variables para recordar la fecha/hora de la vela anterior
    my ($last_year, $last_month, $last_day, $last_hour) = (-1, -1, -1, -1);
    my $have_prev = 0;    # Flag: ¿tenemos una vela anterior válida?

    # Recorrer todas las velas (por índice)
    for my $i (0 .. $#$arr) {
        # Intentar parsear el timestamp usando Time::Moment
        # El timestamp está en la posición 0 de la vela
        my $tm = eval { Time::Moment->from_string($arr->[$i]->[0]) };
        next unless $tm;    # Si no se puede parsear, omitir esta vela

        # Extraer componentes de fecha/hora
        my $year  = $tm->year;
        my $month = $tm->month;
        my $day   = $tm->day_of_month;
        my $hour  = $tm->hour;

        # Detectar si cambió el día (año, mes o día diferentes)
        my $day_changed  = ($year != $last_year)
                        || ($month != $last_month)
                        || ($day != $last_day);
        
        # Detectar si cambió la hora (dentro del mismo día)
        my $hour_changed = ($hour != $last_hour);

        # Si hubo algún cambio (hora o día), registrar un ancla
        if ($day_changed || $hour_changed) {
            # is_date solo cuando hay una vela anterior real con la que comparar
            # y además cambió el día (no solo la hora)
            my $is_date = ($day_changed && $have_prev) ? 1 : 0;
            push @anchors, { index => $i, is_date => $is_date };
        }

        # Guardar los valores actuales como "anteriores" para la próxima iteración
        ($last_year, $last_month, $last_day, $last_hour) =
            ($year, $month, $day, $hour);
        $have_prev = 1;    # A partir de ahora, tenemos una vela anterior
    }

    return \@anchors;  
}

1; 